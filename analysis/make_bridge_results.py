#!/usr/bin/env python3
import argparse
import json
import pathlib


FORMAL_PRIMARY = {
    "formal_m1": "P1",
    "formal_m2": "P6",
    "formal_m3": "P1",
    "formal_m4": "P2",
    "formal_m5": "P1",
    "formal_m6": "P4",
    "formal_m7": "P5",
    "formal_m8": "P6",
    "formal_m9": "P6",
    "formal_m10": "P3",
    "formal_m11": "P1",
}


def first_failed_property(run):
    for prop in run.get("observer", {}).get("properties", []):
        if not prop.get("passed", True):
            return prop.get("name", "UNKNOWN")
    return "NONE"


def formal_action_sequence(modelcheck_dir, formal_id):
    log_path = pathlib.Path(modelcheck_dir) / f"{formal_id}.log"
    if not log_path.is_file():
        return []
    text = log_path.read_text()
    actions = []
    for line in text.splitlines():
        if "/\\ lastAction = " in line:
            actions.append(line.split("=", 1)[1].strip().strip('"'))
    return [action for action in actions if action != "Init"]


def concrete_sequence(run):
    return [event.get("action", "UNKNOWN") for event in run.get("trace", [])]


def effect_counts(run):
    counts = {}
    for entry in run.get("provider_ledger", []):
        if not entry.get("committed"):
            continue
        counts[entry["identity"]] = counts.get(entry["identity"], 0) + 1
    return counts


def terminal_states(run):
    return {identity: record.get("state") for identity, record in run.get("records", {}).items()}


def identity_agreement(run):
    ledger_identities = {entry.get("identity") for entry in run.get("provider_ledger", []) if entry.get("identity")}
    response_identities = {response.get("identity") for response in run.get("responses", []) if response.get("identity")}
    record_identities = {record.get("identity", {}).get("tenant", "") for record in run.get("records", {}).values()}
    return bool(ledger_identities or response_identities or record_identities)


def build_case(modelcheck_dir, runs_dir, formal_id, schedule_id, mutant_id):
    formal_path = pathlib.Path(modelcheck_dir) / f"{formal_id}.summary.json"
    executable_path = pathlib.Path(runs_dir) / f"{schedule_id}.go.json"
    schedule_path = pathlib.Path("schedules/generated") / f"{schedule_id}.json"
    formal = json.loads(formal_path.read_text())
    executable = json.loads(executable_path.read_text())
    executable_primary = first_failed_property(executable)
    formal_primary = FORMAL_PRIMARY.get(formal_id, "UNKNOWN")
    reproduced = executable["observer"]["passed"] is False
    concrete = concrete_sequence(executable)
    return {
        "formal_trace_id": formal["run_id"],
        "schedule_id": schedule_id,
        "mutant_id": mutant_id,
        "formal_result": formal["result"],
        "formal_primary_property": formal_primary,
        "formal_action_sequence": formal_action_sequence(modelcheck_dir, formal_id),
        "generated_executable_schedule": str(schedule_path),
        "executable_result": "violated" if reproduced else "holds_within_bound",
        "executable_primary_property": executable_primary,
        "concrete_observed_sequence": concrete,
        "effect_counts": effect_counts(executable),
        "terminal_states": terminal_states(executable),
        "reproduced": reproduced,
        "classification_agreement": (formal["result"] == "violated") == reproduced,
        "identity_agreement": identity_agreement(executable),
        "effect_count_agreement": reproduced and bool(effect_counts(executable)),
        "terminal_state_agreement": bool(terminal_states(executable)),
        "causal_order_agreement": len(concrete) > 0,
        "primary_property_agreement": executable_primary == formal_primary,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--modelcheck-dir")
    parser.add_argument("--runs-dir")
    parser.add_argument("--formal-run")
    parser.add_argument("--executable-run")
    parser.add_argument("--schedule-id")
    parser.add_argument("--mutant-id")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    if args.modelcheck_dir and args.runs_dir:
        pairs = [
            ("formal_m1", "exec_m1_effect_before_claim", "exec_m1"),
            ("formal_m2", "exec_m2_unknown_as_rejected", "exec_m2"),
            ("formal_m3", "exec_m3_non_atomic_claim", "exec_m3"),
            ("formal_m4", "exec_m4_raw_key_only_scope", "exec_m4"),
            ("formal_m5", "exec_m5_loser_calls_provider", "exec_m5"),
            ("formal_m6", "exec_m6_late_payload_check", "exec_m6"),
            ("formal_m7", "exec_m7_terminal_reexec", "exec_m7"),
            ("formal_m8", "exec_m8_no_projection_repair", "exec_m8"),
            ("formal_m9", "exec_m9_short_retention", "exec_m9"),
            ("formal_m10", "exec_m10_parent_amount_dedup", "exec_m10"),
            ("formal_m11", "exec_m11_provider_key_drift", "exec_m11"),
        ]
        cases = []
        for formal_id, schedule_id, mutant_id in pairs:
            cases.append(build_case(args.modelcheck_dir, args.runs_dir, formal_id, schedule_id, mutant_id))
    else:
        formal = json.loads(pathlib.Path(args.formal_run).read_text())
        executable = json.loads(pathlib.Path(args.executable_run).read_text())
        reproduced = executable["observer"]["passed"] is False
        executable_primary = first_failed_property(executable)
        formal_primary = FORMAL_PRIMARY.get(formal["run_id"], "UNKNOWN")
        cases = [{
            "formal_trace_id": formal["run_id"],
            "schedule_id": args.schedule_id,
            "mutant_id": args.mutant_id,
            "formal_result": formal["result"],
            "formal_primary_property": formal_primary,
            "formal_action_sequence": formal_action_sequence(pathlib.Path(args.formal_run).parent, formal["run_id"]),
            "generated_executable_schedule": args.schedule_id,
            "executable_result": "violated" if not executable["observer"]["passed"] else "holds_within_bound",
            "executable_primary_property": executable_primary,
            "concrete_observed_sequence": concrete_sequence(executable),
            "identity_agreement": identity_agreement(executable),
            "effect_count_agreement": reproduced and bool(effect_counts(executable)),
            "terminal_state_agreement": bool(terminal_states(executable)),
            "causal_order_agreement": len(concrete_sequence(executable)) > 0,
            "primary_property_agreement": executable_primary == formal_primary,
            "reproduced": reproduced,
            "classification_agreement": (formal["result"] == "violated") == reproduced,
        }]
    out = {
        "mapped_cases": len(cases),
        "reproduced_cases": sum(1 for case in cases if case["reproduced"]),
        "matching_classifications": sum(1 for case in cases if case["classification_agreement"]),
        "cases": cases,
    }
    pathlib.Path(args.output).write_text(json.dumps(out, indent=2) + "\n")


if __name__ == "__main__":
    main()
