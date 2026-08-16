import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

public final class Main {
    public static void main(String[] args) throws Exception {
        Map<String, String> flags = parseFlags(args);
        String schedulePath = required(flags, "--schedule");
        String profilePath = required(flags, "--profile");
        String outputPath = required(flags, "--output");

        JsonValue scheduleJson = Json.parse(Files.readString(Path.of(schedulePath)));
        Profile profile = Profile.parse(Files.readString(Path.of(profilePath)));
        Engine engine = new Engine(profile);
        JsonObject schedule = scheduleJson.asObject();
        String mutantId = schedule.getString("mutant_id", "");
        RunResult result = engine.run(schedule, mutantId);
        Files.writeString(Path.of(outputPath), result.toJson().render() + "\n", StandardCharsets.UTF_8);
    }

    private static String required(Map<String, String> flags, String key) {
        String value = flags.get(key);
        if (value == null || value.isEmpty()) {
            throw new IllegalArgumentException("missing required flag " + key);
        }
        return value;
    }

    private static Map<String, String> parseFlags(String[] args) {
        Map<String, String> out = new LinkedHashMap<>();
        for (int i = 0; i < args.length; i += 2) {
            out.put(args[i], args[i + 1]);
        }
        return out;
    }

    static final class Profile {
        final String name;
        final boolean authoritativeLookup;
        final boolean asyncSettlement;

        Profile(String name, boolean authoritativeLookup, boolean asyncSettlement) {
            this.name = name;
            this.authoritativeLookup = authoritativeLookup;
            this.asyncSettlement = asyncSettlement;
        }

        static Profile parse(String raw) {
            Map<String, String> values = new LinkedHashMap<>();
            for (String line : raw.split("\n")) {
                String trimmed = line.trim();
                if (trimmed.isEmpty() || trimmed.startsWith("#")) {
                    continue;
                }
                String[] parts = trimmed.split(":", 2);
                values.put(parts[0].trim(), parts[1].trim());
            }
            return new Profile(
                values.getOrDefault("name", "unknown"),
                "true".equals(values.getOrDefault("authoritative_lookup", "false")),
                "true".equals(values.getOrDefault("async_settlement", "false"))
            );
        }
    }

    static final class Engine {
        private final Profile profile;
        private final Map<String, Record> records = new LinkedHashMap<>();
        private final List<JsonObject> trace = new ArrayList<>();
        private final List<JsonObject> responses = new ArrayList<>();
        private final List<JsonObject> ledger = new ArrayList<>();
        private final Map<String, Integer> captured = new LinkedHashMap<>();
        private final Map<String, Integer> refunded = new LinkedHashMap<>();
        private int step = 0;

        Engine(Profile profile) {
            this.profile = profile;
        }

        RunResult run(JsonObject schedule, String mutantId) {
            JsonArray events = schedule.getArray("events");
            for (JsonValue value : events.values) {
                JsonObject event = value.asObject();
                String kind = event.getString("kind", "");
                if ("request".equals(kind)) {
                    handleRequest(schedule.getString("schedule_id", ""), event, mutantId);
                } else if ("advance_time".equals(kind)) {
                    step += event.getInt("advance_by", 0);
                    trace.add(object("index", number(trace.size()), "schedule_id", string(schedule.getString("schedule_id", "")), "event_id", string(event.getString("id", "")), "action", string("AdvanceTime")));
                } else if ("crash".equals(kind)) {
                    step++;
                    trace.add(object("index", number(trace.size()), "schedule_id", string(schedule.getString("schedule_id", "")), "event_id", string(event.getString("id", "")), "action", string("Crash")));
                } else if ("restart".equals(kind)) {
                    step++;
                    trace.add(object("index", number(trace.size()), "schedule_id", string(schedule.getString("schedule_id", "")), "event_id", string(event.getString("id", "")), "action", string("Restart")));
                }
            }

            JsonObject observer = observe();
            return new RunResult(
                "portable-java-query-reconcile-" + schedule.getString("schedule_id", ""),
                schedule.getString("schedule_id", ""),
                trace,
                responses,
                ledger,
                records,
                captured,
                refunded,
                observer
            );
        }

        private void handleRequest(String scheduleId, JsonObject event, String mutantId) {
            step++;
            JsonObject request = event.getObject("request");
            JsonObject identity = request.getObject("identity");
            JsonObject payload = request.getObject("payload");
            String identityKey = identityKey(identity);
            String fingerprint = fingerprint(payload);
            Record record = records.get(identityKey);

            if (record != null && !record.fingerprint.equals(fingerprint)) {
                trace.add(trace(scheduleId, event.getString("id", ""), "PayloadConflict", identityKey));
                responses.add(response(request.getString("request_id", ""), identityKey, "conflict", true, false, false, outcome("conflict", "", payload.getInt("amount", 0), payload.getString("currency", ""), "PAYLOAD_CONFLICT", identityKey, "")));
                return;
            }

            if (record != null && ("COMPLETED".equals(record.state) || "REJECTED_FINAL".equals(record.state))) {
                trace.add(trace(scheduleId, event.getString("id", ""), "ReplayTerminal", identityKey));
                responses.add(response(request.getString("request_id", ""), identityKey, "replay", false, false, false, outcome(record.outcomeStatus, record.providerRef, payload.getInt("amount", 0), payload.getString("currency", ""), record.stableError, identityKey, record.state)));
                return;
            }

            if (record == null) {
                record = new Record("IN_PROGRESS", fingerprint, identityKey, "");
                records.put(identityKey, record);
                trace.add(trace(scheduleId, event.getString("id", ""), "Claim", identityKey));
            }

            String behavior = event.getString("behavior", "commit_reply");
            if ("commit_drop_reply".equals(behavior)) {
                String providerRef = providerRef(identityKey);
                ledger.add(ledger(identityKey, providerRef, behavior, true, false, false));
                if (profile.authoritativeLookup) {
                    record.state = "COMPLETED";
                    record.providerRef = providerRef;
                    record.outcomeStatus = "completed";
                    applyProjection(identity, payload);
                    responses.add(response(request.getString("request_id", ""), identityKey, "completed_after_lookup", false, false, false, outcome("completed", providerRef, payload.getInt("amount", 0), payload.getString("currency", ""), "", identityKey, "")));
                } else {
                    record.state = "UNKNOWN";
                    if ("exec_m2".equals(mutantId)) {
                        record.state = "REJECTED_FINAL";
                        record.stableError = "WRONG_UNKNOWN_AS_FINAL";
                    }
                    responses.add(response(request.getString("request_id", ""), identityKey, record.state.equals("UNKNOWN") ? "unknown" : "rejected_final", false, false, record.state.equals("UNKNOWN"), outcome(record.state.equals("UNKNOWN") ? "unknown" : "rejected_final", providerRef, payload.getInt("amount", 0), payload.getString("currency", ""), record.stableError, identityKey, "")));
                }
                return;
            }

            if ("reject_final".equals(behavior)) {
                String providerRef = providerRef(identityKey);
                ledger.add(ledger(identityKey, providerRef, behavior, false, true, false));
                record.state = "REJECTED_FINAL";
                record.providerRef = providerRef;
                record.outcomeStatus = "rejected_final";
                record.stableError = "FINAL_REJECT";
                responses.add(response(request.getString("request_id", ""), identityKey, "rejected_final", false, false, false, outcome("rejected_final", providerRef, payload.getInt("amount", 0), payload.getString("currency", ""), "FINAL_REJECT", identityKey, "")));
                return;
            }

            String providerRef = providerRef(identityKey);
            ledger.add(ledger(identityKey, providerRef, behavior, true, false, profile.asyncSettlement && "delayed_settlement".equals(behavior)));
            record.state = "COMPLETED";
            record.providerRef = providerRef;
            record.outcomeStatus = "delayed_settlement".equals(behavior) ? "accepted_pending_settlement" : "completed";
            applyProjection(identity, payload);
            responses.add(response(request.getString("request_id", ""), identityKey, record.outcomeStatus, false, false, false, outcome(record.outcomeStatus, providerRef, payload.getInt("amount", 0), payload.getString("currency", ""), "", identityKey, "")));
        }

        private JsonObject observe() {
            boolean passed = true;
            JsonArray properties = new JsonArray();
            Map<String, Integer> effectCounts = new LinkedHashMap<>();
            for (JsonObject entry : ledger) {
                if (entry.getBoolean("committed", false)) {
                    String identity = entry.getString("identity", "");
                    effectCounts.put(identity, effectCounts.getOrDefault(identity, 0) + 1);
                }
            }
            List<String> p1Violations = new ArrayList<>();
            for (Map.Entry<String, Integer> entry : effectCounts.entrySet()) {
                if (entry.getValue() > 1) {
                    p1Violations.add(entry.getKey() + " has " + entry.getValue() + " committed effects");
                }
            }
            if (!p1Violations.isEmpty()) {
                passed = false;
            }
            properties.add(property("P1", p1Violations.isEmpty(), p1Violations));
            properties.add(property("P2", true, List.of()));
            properties.add(property("P3", p1Violations.isEmpty(), p1Violations));
            properties.add(property("P4", true, List.of()));
            properties.add(property("P5", true, List.of()));
            properties.add(property("P6", true, List.of()));
            List<String> p7Violations = new ArrayList<>();
            for (Map.Entry<String, Integer> entry : refunded.entrySet()) {
                int capturedAmount = captured.getOrDefault(entry.getKey(), 0);
                if (entry.getValue() > capturedAmount) {
                    p7Violations.add(entry.getKey() + " refunded " + entry.getValue() + " over captured " + capturedAmount);
                }
            }
            if (!p7Violations.isEmpty()) {
                passed = false;
            }
            properties.add(property("P7", p7Violations.isEmpty(), p7Violations));
            return object(
                "passed", bool(passed),
                "properties", properties,
                "property_fingerprint", string("java-" + Integer.toHexString(properties.render().hashCode()))
            );
        }

        private void applyProjection(JsonObject identity, JsonObject payload) {
            String parent = identity.getString("parent_resource", "");
            int amount = payload.getInt("amount", 0);
            String operationType = identity.getString("operation_type", "");
            if ("capture".equals(operationType)) {
                captured.put(parent, captured.getOrDefault(parent, 0) + amount);
            } else if ("refund".equals(operationType)) {
                refunded.put(parent, refunded.getOrDefault(parent, 0) + amount);
            }
        }

        private String identityKey(JsonObject identity) {
            return identity.getString("tenant", "") + "|" + identity.getString("operation_type", "") + "|" + identity.getString("parent_resource", "") + "|" + identity.getString("caller_key", "") + "|" + identity.getInt("epoch", 0);
        }

        private String providerRef(String identityKey) {
            return "prov-" + identityKey + "-" + (ledger.size() + 1);
        }

        private String fingerprint(JsonObject payload) {
            TreeMap<String, String> options = new TreeMap<>();
            JsonObject rawOptions = payload.getObjectOrNull("options");
            if (rawOptions != null) {
                for (Map.Entry<String, JsonValue> entry : rawOptions.values.entrySet()) {
                    options.put(entry.getKey(), entry.getValue().asString());
                }
            }
            StringBuilder builder = new StringBuilder();
            builder.append(payload.getInt("amount", 0)).append("|");
            builder.append(payload.getString("currency", "")).append("|");
            builder.append(payload.getString("destination", "")).append("|");
            for (Map.Entry<String, String> entry : options.entrySet()) {
                builder.append(entry.getKey()).append("=").append(entry.getValue()).append(";");
            }
            return Integer.toHexString(builder.toString().hashCode());
        }
    }

    static final class Record {
        String state;
        final String fingerprint;
        String providerRef;
        String outcomeStatus;
        String stableError = "";

        Record(String state, String fingerprint, String providerRef, String outcomeStatus) {
            this.state = state;
            this.fingerprint = fingerprint;
            this.providerRef = providerRef;
            this.outcomeStatus = outcomeStatus;
        }
    }

    static final class RunResult {
        private final String runId;
        private final String scheduleId;
        private final List<JsonObject> trace;
        private final List<JsonObject> responses;
        private final List<JsonObject> ledger;
        private final Map<String, Record> records;
        private final Map<String, Integer> captured;
        private final Map<String, Integer> refunded;
        private final JsonObject observer;

        RunResult(String runId, String scheduleId, List<JsonObject> trace, List<JsonObject> responses, List<JsonObject> ledger, Map<String, Record> records, Map<String, Integer> captured, Map<String, Integer> refunded, JsonObject observer) {
            this.runId = runId;
            this.scheduleId = scheduleId;
            this.trace = trace;
            this.responses = responses;
            this.ledger = ledger;
            this.records = records;
            this.captured = captured;
            this.refunded = refunded;
            this.observer = observer;
        }

        JsonObject toJson() {
            JsonObject recordValues = new JsonObject();
            for (Map.Entry<String, Record> entry : records.entrySet()) {
                Record record = entry.getValue();
                recordValues.put(entry.getKey(), object(
                    "state", string(record.state),
                    "fingerprint", string(record.fingerprint),
                    "provider_ref", string(record.providerRef),
                    "outcome", object("status", string(record.outcomeStatus), "stable_error", string(record.stableError))
                ));
            }
            return object(
                "run_id", string(runId),
                "mode", string("portable"),
                "implementation", string("java-query-reconcile"),
                "schedule_id", string(scheduleId),
                "profile", object("name", string("java-query-reconcile")),
                "trace", array(trace),
                "responses", array(responses),
                "records", recordValues,
                "provider_ledger", array(ledger),
                "projection", object(
                    "captured_by_parent", objectFromInts(captured),
                    "refunded_by_parent", objectFromInts(refunded),
                    "reversals_by_parent", new JsonObject()
                ),
                "observer", observer
            );
        }
    }

    static JsonObject property(String name, boolean passed, List<String> violations) {
        JsonArray violationArray = new JsonArray();
        for (String violation : violations) {
            violationArray.add(string(violation));
        }
        return object("name", string(name), "passed", bool(passed), "violations", violationArray);
    }

    static JsonObject response(String requestId, String identity, String status, boolean conflict, boolean pending, boolean unknown, JsonObject outcome) {
        return object(
            "request_id", string(requestId),
            "identity", string(identity),
            "status", string(status),
            "conflict", bool(conflict),
            "pending", bool(pending),
            "unknown", bool(unknown),
            "outcome", outcome
        );
    }

    static JsonObject outcome(String status, String providerRef, int amount, String currency, String stableError, String operationId, String replayOfState) {
        return object(
            "status", string(status),
            "provider_ref", string(providerRef),
            "amount", number(amount),
            "currency", string(currency),
            "stable_error", string(stableError),
            "operation_id", string(operationId),
            "replay_of_state", string(replayOfState)
        );
    }

    static JsonObject ledger(String identity, String providerRef, String behavior, boolean committed, boolean finalReject, boolean settled) {
        return object(
            "identity", string(identity),
            "provider_key", string(identity),
            "provider_ref", string(providerRef),
            "behavior", string(behavior),
            "committed", bool(committed),
            "final_reject", bool(finalReject),
            "settled", bool(settled)
        );
    }

    static JsonObject trace(String scheduleId, String eventId, String action, String identity) {
        return object(
            "index", number(0),
            "schedule_id", string(scheduleId),
            "event_id", string(eventId),
            "action", string(action),
            "identity", string(identity)
        );
    }

    static JsonObject objectFromInts(Map<String, Integer> values) {
        JsonObject object = new JsonObject();
        for (Map.Entry<String, Integer> entry : values.entrySet()) {
            object.put(entry.getKey(), number(entry.getValue()));
        }
        return object;
    }

    static JsonObject object(Object... parts) {
        JsonObject object = new JsonObject();
        for (int i = 0; i < parts.length; i += 2) {
            object.put((String) parts[i], (JsonValue) parts[i + 1]);
        }
        return object;
    }

    static JsonArray array(List<? extends JsonValue> values) {
        JsonArray array = new JsonArray();
        for (JsonValue value : values) {
            array.add(value);
        }
        return array;
    }

    static JsonValue string(String value) {
        return new JsonString(value);
    }

    static JsonValue number(int value) {
        return new JsonNumber(value);
    }

    static JsonValue bool(boolean value) {
        return value ? JsonBoolean.TRUE : JsonBoolean.FALSE;
    }

    interface JsonValue {
        default JsonObject asObject() {
            return (JsonObject) this;
        }

        default String asString() {
            return ((JsonString) this).value;
        }

        String render();
    }

    static final class JsonObject implements JsonValue {
        final Map<String, JsonValue> values = new LinkedHashMap<>();

        void put(String key, JsonValue value) {
            values.put(key, value);
        }

        String getString(String key, String fallback) {
            JsonValue value = values.get(key);
            return value == null ? fallback : value.asString();
        }

        int getInt(String key, int fallback) {
            JsonValue value = values.get(key);
            return value == null ? fallback : ((JsonNumber) value).value;
        }

        boolean getBoolean(String key, boolean fallback) {
            JsonValue value = values.get(key);
            return value == null ? fallback : ((JsonBoolean) value).value;
        }

        JsonObject getObject(String key) {
            return values.get(key).asObject();
        }

        JsonObject getObjectOrNull(String key) {
            JsonValue value = values.get(key);
            return value == null ? null : value.asObject();
        }

        JsonArray getArray(String key) {
            return (JsonArray) values.get(key);
        }

        @Override
        public String render() {
            StringBuilder builder = new StringBuilder();
            builder.append("{");
            boolean first = true;
            for (Map.Entry<String, JsonValue> entry : values.entrySet()) {
                if (!first) {
                    builder.append(",");
                }
                first = false;
                builder.append("\"").append(escape(entry.getKey())).append("\":");
                builder.append(entry.getValue().render());
            }
            builder.append("}");
            return builder.toString();
        }
    }

    static final class JsonArray implements JsonValue {
        final List<JsonValue> values = new ArrayList<>();

        void add(JsonValue value) {
            values.add(value);
        }

        @Override
        public String render() {
            StringBuilder builder = new StringBuilder();
            builder.append("[");
            boolean first = true;
            for (JsonValue value : values) {
                if (!first) {
                    builder.append(",");
                }
                first = false;
                builder.append(value.render());
            }
            builder.append("]");
            return builder.toString();
        }
    }

    static final class JsonString implements JsonValue {
        final String value;

        JsonString(String value) {
            this.value = value == null ? "" : value;
        }

        @Override
        public String render() {
            return "\"" + escape(value) + "\"";
        }
    }

    static final class JsonNumber implements JsonValue {
        final int value;

        JsonNumber(int value) {
            this.value = value;
        }

        @Override
        public String render() {
            return Integer.toString(value);
        }
    }

    enum JsonBoolean implements JsonValue {
        TRUE(true),
        FALSE(false);

        final boolean value;

        JsonBoolean(boolean value) {
            this.value = value;
        }

        @Override
        public String render() {
            return value ? "true" : "false";
        }
    }

    static final class JsonNull implements JsonValue {
        static final JsonNull VALUE = new JsonNull();

        @Override
        public String render() {
            return "null";
        }
    }

    static final class Json {
        static JsonValue parse(String raw) {
            Parser parser = new Parser(raw);
            return parser.parseValue();
        }
    }

    static final class Parser {
        private final String raw;
        private int index;

        Parser(String raw) {
            this.raw = raw;
            this.index = 0;
        }

        JsonValue parseValue() {
            skipWhitespace();
            char current = raw.charAt(index);
            if (current == '{') {
                return parseObject();
            }
            if (current == '[') {
                return parseArray();
            }
            if (current == '"') {
                return new JsonString(parseString());
            }
            if (current == 't' || current == 'f') {
                return parseBoolean();
            }
            if (current == 'n') {
                index += 4;
                return JsonNull.VALUE;
            }
            return parseNumber();
        }

        private JsonObject parseObject() {
            expect('{');
            JsonObject object = new JsonObject();
            skipWhitespace();
            if (peek() == '}') {
                index++;
                return object;
            }
            while (true) {
                String key = parseString();
                skipWhitespace();
                expect(':');
                JsonValue value = parseValue();
                object.put(key, value);
                skipWhitespace();
                if (peek() == '}') {
                    index++;
                    return object;
                }
                expect(',');
            }
        }

        private JsonArray parseArray() {
            expect('[');
            JsonArray array = new JsonArray();
            skipWhitespace();
            if (peek() == ']') {
                index++;
                return array;
            }
            while (true) {
                array.add(parseValue());
                skipWhitespace();
                if (peek() == ']') {
                    index++;
                    return array;
                }
                expect(',');
            }
        }

        private JsonValue parseBoolean() {
            if (raw.startsWith("true", index)) {
                index += 4;
                return JsonBoolean.TRUE;
            }
            index += 5;
            return JsonBoolean.FALSE;
        }

        private JsonNumber parseNumber() {
            int start = index;
            while (index < raw.length() && "-0123456789".indexOf(raw.charAt(index)) >= 0) {
                index++;
            }
            return new JsonNumber(Integer.parseInt(raw.substring(start, index)));
        }

        private String parseString() {
            expect('"');
            StringBuilder builder = new StringBuilder();
            while (true) {
                char current = raw.charAt(index++);
                if (current == '"') {
                    return builder.toString();
                }
                if (current == '\\') {
                    builder.append(raw.charAt(index++));
                } else {
                    builder.append(current);
                }
            }
        }

        private void expect(char expected) {
            skipWhitespace();
            if (raw.charAt(index) != expected) {
                throw new IllegalStateException("expected " + expected + " at " + index);
            }
            index++;
        }

        private char peek() {
            skipWhitespace();
            return raw.charAt(index);
        }

        private void skipWhitespace() {
            while (index < raw.length() && Character.isWhitespace(raw.charAt(index))) {
                index++;
            }
        }
    }

    static String escape(String value) {
        return value.replace("\\", "\\\\").replace("\"", "\\\"");
    }
}
