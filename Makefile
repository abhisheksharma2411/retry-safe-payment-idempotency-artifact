SHELL := /bin/sh

ROOT := $(CURDIR)
GOCACHE := $(ROOT)/.gocache
GOMODCACHE := $(ROOT)/.gomodcache
PYTHONPYCACHEPREFIX := $(ROOT)/.pycache
GOENV := env GOCACHE="$(GOCACHE)" GOMODCACHE="$(GOMODCACHE)"
PYENV := env PYTHONPYCACHEPREFIX="$(PYTHONPYCACHEPREFIX)"

SAFE_GO_RESULTS := \
	results/raw/changed_payload_all_states.go.json \
	results/raw/unknown_outcome_lookup_provider.go.json \
	results/raw/unknown_outcome_opaque_provider.go.json \
	results/raw/two_equal_partial_refunds.go.json

SAFE_JAVA_RESULTS := \
	results/raw/changed_payload_all_states.java.json \
	results/raw/unknown_outcome_lookup_provider.java.json \
	results/raw/unknown_outcome_opaque_provider.java.json \
	results/raw/two_equal_partial_refunds.java.json

MUTANT_RESULTS := \
	results/raw/exec_m1_effect_before_claim.go.json \
	results/raw/exec_m2_unknown_as_rejected.go.json \
	results/raw/exec_m3_non_atomic_claim.go.json \
	results/raw/exec_m4_raw_key_only_scope.go.json \
	results/raw/exec_m5_loser_calls_provider.go.json \
	results/raw/exec_m6_late_payload_check.go.json \
	results/raw/exec_m7_terminal_reexec.go.json \
	results/raw/exec_m8_no_projection_repair.go.json \
	results/raw/exec_m9_short_retention.go.json \
	results/raw/exec_m10_parent_amount_dedup.go.json \
	results/raw/exec_m11_provider_key_drift.go.json

.PHONY: bootstrap clean-results lint test check-spec-smoke check-spec-all test-references test-mutants test-determinism test-reductions safe-pairs replay-formal-counterexamples validate-campaign normalize-results public-artifact-acceptance

bootstrap:
	mkdir -p "$(GOCACHE)" "$(GOMODCACHE)" "$(PYTHONPYCACHEPREFIX)" results/raw results/normalized results/tables results/figures results/report modelcheck/raw tmpbin modelcheck/tools

clean-results:
	rm -rf results/raw results/normalized results/tables results/figures results/report modelcheck/raw
	mkdir -p results/raw results/normalized results/tables results/figures results/report modelcheck/raw

lint: bootstrap
	gofmt -w internal/core/*.go harness/cooperative/*.go harness/shrinker/*.go harness/cmd/run_schedule/*.go harness/cmd/reduce_trace/*.go references/go-reserve-replay/*.go
	$(PYENV) python3 -m py_compile analysis/*.py scripts/*.py modelcheck/scripts/*.py

test: bootstrap
	$(GOENV) go test ./...

modelcheck/tools/tla2tools.jar:
	$(PYENV) python3 scripts/fetch_tla_tools.py

check-spec-smoke: bootstrap modelcheck/tools/tla2tools.jar
	$(PYENV) env T8_TLC_DOCKER=1 python3 modelcheck/scripts/run_tlc.py --smoke

check-spec-all: bootstrap modelcheck/tools/tla2tools.jar
	$(PYENV) env T8_TLC_DOCKER=1 python3 modelcheck/scripts/run_tlc.py --all

results/raw/changed_payload_all_states.go.json: schedules/public/changed_payload_all_states.json profiles/idempotent-replay.yaml
	$(GOENV) go run ./harness/cmd/run_schedule --mode cooperative --implementation go-reserve-replay --schedule $< --profile profiles/idempotent-replay.yaml --output $@

results/raw/unknown_outcome_lookup_provider.go.json: schedules/public/unknown_outcome_lookup_provider.json profiles/authoritative-lookup.yaml
	$(GOENV) go run ./harness/cmd/run_schedule --mode cooperative --implementation go-reserve-replay --schedule $< --profile profiles/authoritative-lookup.yaml --output $@

results/raw/unknown_outcome_opaque_provider.go.json: schedules/public/unknown_outcome_opaque_provider.json profiles/opaque-provider.yaml
	$(GOENV) go run ./harness/cmd/run_schedule --mode cooperative --implementation go-reserve-replay --schedule $< --profile profiles/opaque-provider.yaml --output $@

results/raw/two_equal_partial_refunds.go.json: schedules/public/two_equal_partial_refunds.json profiles/idempotent-replay.yaml
	$(GOENV) go run ./harness/cmd/run_schedule --mode cooperative --implementation go-reserve-replay --schedule $< --profile profiles/idempotent-replay.yaml --output $@

results/raw/changed_payload_all_states.java.json: schedules/public/changed_payload_all_states.json profiles/idempotent-replay.yaml
	docker run --rm -v "$(ROOT):/work" -w /work eclipse-temurin:21-jdk sh -lc 'mkdir -p tmpbin/java-query-reconcile && javac -d tmpbin/java-query-reconcile references/java-query-reconcile/src/Main.java && java -cp tmpbin/java-query-reconcile Main --schedule $< --profile profiles/idempotent-replay.yaml --output $@'

results/raw/unknown_outcome_lookup_provider.java.json: schedules/public/unknown_outcome_lookup_provider.json profiles/authoritative-lookup.yaml
	docker run --rm -v "$(ROOT):/work" -w /work eclipse-temurin:21-jdk sh -lc 'mkdir -p tmpbin/java-query-reconcile && javac -d tmpbin/java-query-reconcile references/java-query-reconcile/src/Main.java && java -cp tmpbin/java-query-reconcile Main --schedule $< --profile profiles/authoritative-lookup.yaml --output $@'

results/raw/unknown_outcome_opaque_provider.java.json: schedules/public/unknown_outcome_opaque_provider.json profiles/opaque-provider.yaml
	docker run --rm -v "$(ROOT):/work" -w /work eclipse-temurin:21-jdk sh -lc 'mkdir -p tmpbin/java-query-reconcile && javac -d tmpbin/java-query-reconcile references/java-query-reconcile/src/Main.java && java -cp tmpbin/java-query-reconcile Main --schedule $< --profile profiles/opaque-provider.yaml --output $@'

results/raw/two_equal_partial_refunds.java.json: schedules/public/two_equal_partial_refunds.json profiles/idempotent-replay.yaml
	docker run --rm -v "$(ROOT):/work" -w /work eclipse-temurin:21-jdk sh -lc 'mkdir -p tmpbin/java-query-reconcile && javac -d tmpbin/java-query-reconcile references/java-query-reconcile/src/Main.java && java -cp tmpbin/java-query-reconcile Main --schedule $< --profile profiles/idempotent-replay.yaml --output $@'

results/raw/exec_m1_effect_before_claim.go.json: schedules/generated/exec_m1_effect_before_claim.json profiles/idempotent-replay.yaml
	$(GOENV) go run ./harness/cmd/run_schedule --mode cooperative --implementation go-reserve-replay --schedule $< --profile profiles/idempotent-replay.yaml --output $@

results/raw/exec_m2_unknown_as_rejected.go.json: schedules/generated/exec_m2_unknown_as_rejected.json profiles/opaque-provider.yaml
	$(GOENV) go run ./harness/cmd/run_schedule --mode cooperative --implementation go-reserve-replay --schedule $< --profile profiles/opaque-provider.yaml --output $@

results/raw/exec_m3_non_atomic_claim.go.json: schedules/generated/exec_m3_non_atomic_claim.json profiles/idempotent-replay.yaml
	$(GOENV) go run ./harness/cmd/run_schedule --mode cooperative --implementation go-reserve-replay --schedule $< --profile profiles/idempotent-replay.yaml --output $@

results/raw/exec_m4_raw_key_only_scope.go.json: schedules/generated/exec_m4_raw_key_only_scope.json profiles/idempotent-replay.yaml
	$(GOENV) go run ./harness/cmd/run_schedule --mode cooperative --implementation go-reserve-replay --schedule $< --profile profiles/idempotent-replay.yaml --output $@

results/raw/exec_m5_loser_calls_provider.go.json: schedules/generated/exec_m5_loser_calls_provider.json profiles/idempotent-replay.yaml
	$(GOENV) go run ./harness/cmd/run_schedule --mode cooperative --implementation go-reserve-replay --schedule $< --profile profiles/idempotent-replay.yaml --output $@

results/raw/exec_m6_late_payload_check.go.json: schedules/generated/exec_m6_late_payload_check.json profiles/idempotent-replay.yaml
	$(GOENV) go run ./harness/cmd/run_schedule --mode cooperative --implementation go-reserve-replay --schedule $< --profile profiles/idempotent-replay.yaml --output $@

results/raw/exec_m7_terminal_reexec.go.json: schedules/generated/exec_m7_terminal_reexec.json profiles/idempotent-replay.yaml
	$(GOENV) go run ./harness/cmd/run_schedule --mode cooperative --implementation go-reserve-replay --schedule $< --profile profiles/idempotent-replay.yaml --output $@

results/raw/exec_m8_no_projection_repair.go.json: schedules/generated/exec_m8_no_projection_repair.json profiles/authoritative-lookup.yaml
	$(GOENV) go run ./harness/cmd/run_schedule --mode cooperative --implementation go-reserve-replay --schedule $< --profile profiles/authoritative-lookup.yaml --output $@

results/raw/exec_m9_short_retention.go.json: schedules/generated/exec_m9_short_retention.json profiles/idempotent-replay.yaml
	$(GOENV) go run ./harness/cmd/run_schedule --mode cooperative --implementation go-reserve-replay --schedule $< --profile profiles/idempotent-replay.yaml --output $@

results/raw/exec_m10_parent_amount_dedup.go.json: schedules/generated/exec_m10_parent_amount_dedup.json profiles/idempotent-replay.yaml
	$(GOENV) go run ./harness/cmd/run_schedule --mode cooperative --implementation go-reserve-replay --schedule $< --profile profiles/idempotent-replay.yaml --output $@

results/raw/exec_m11_provider_key_drift.go.json: schedules/generated/exec_m11_provider_key_drift.json profiles/idempotent-replay.yaml
	$(GOENV) go run ./harness/cmd/run_schedule --mode cooperative --implementation go-reserve-replay --schedule $< --profile profiles/idempotent-replay.yaml --output $@

test-references: bootstrap $(SAFE_GO_RESULTS) $(SAFE_JAVA_RESULTS)
	$(PYENV) python3 analysis/validate_results.py $(SAFE_GO_RESULTS) $(SAFE_JAVA_RESULTS)

safe-pairs: bootstrap
	$(PYENV) python3 analysis/run_safe_pairs.py --root .

test-mutants: bootstrap $(MUTANT_RESULTS)
	$(PYENV) python3 analysis/validate_results.py $(MUTANT_RESULTS)

test-determinism: bootstrap
	$(GOENV) go run ./harness/cmd/run_schedule --mode cooperative --implementation go-reserve-replay --schedule schedules/public/changed_payload_all_states.json --profile profiles/idempotent-replay.yaml --output results/raw/determinism_a.json
	$(GOENV) go run ./harness/cmd/run_schedule --mode cooperative --implementation go-reserve-replay --schedule schedules/public/changed_payload_all_states.json --profile profiles/idempotent-replay.yaml --output results/raw/determinism_b.json
	diff -u results/raw/determinism_a.json results/raw/determinism_b.json

test-reductions: bootstrap $(MUTANT_RESULTS)
	$(GOENV) go run ./harness/cmd/reduce_trace --schedule schedules/generated/exec_m1_effect_before_claim.json --profile profiles/idempotent-replay.yaml --output results/raw/reduced_exec_m1.json --report results/raw/reduced_exec_m1.report.json
	$(GOENV) go run ./harness/cmd/reduce_trace --schedule schedules/generated/exec_m2_unknown_as_rejected.json --profile profiles/opaque-provider.yaml --output results/raw/reduced_exec_m2.json --report results/raw/reduced_exec_m2.report.json
	$(GOENV) go run ./harness/cmd/reduce_trace --schedule schedules/generated/exec_m3_non_atomic_claim.json --profile profiles/idempotent-replay.yaml --output results/raw/reduced_exec_m3.json --report results/raw/reduced_exec_m3.report.json
	$(GOENV) go run ./harness/cmd/reduce_trace --schedule schedules/generated/exec_m4_raw_key_only_scope.json --profile profiles/idempotent-replay.yaml --output results/raw/reduced_exec_m4.json --report results/raw/reduced_exec_m4.report.json
	$(GOENV) go run ./harness/cmd/reduce_trace --schedule schedules/generated/exec_m5_loser_calls_provider.json --profile profiles/idempotent-replay.yaml --output results/raw/reduced_exec_m5.json --report results/raw/reduced_exec_m5.report.json
	$(GOENV) go run ./harness/cmd/reduce_trace --schedule schedules/generated/exec_m6_late_payload_check.json --profile profiles/idempotent-replay.yaml --output results/raw/reduced_exec_m6.json --report results/raw/reduced_exec_m6.report.json
	$(GOENV) go run ./harness/cmd/reduce_trace --schedule schedules/generated/exec_m7_terminal_reexec.json --profile profiles/idempotent-replay.yaml --output results/raw/reduced_exec_m7.json --report results/raw/reduced_exec_m7.report.json
	$(GOENV) go run ./harness/cmd/reduce_trace --schedule schedules/generated/exec_m8_no_projection_repair.json --profile profiles/authoritative-lookup.yaml --output results/raw/reduced_exec_m8.json --report results/raw/reduced_exec_m8.report.json
	$(GOENV) go run ./harness/cmd/reduce_trace --schedule schedules/generated/exec_m9_short_retention.json --profile profiles/idempotent-replay.yaml --output results/raw/reduced_exec_m9.json --report results/raw/reduced_exec_m9.report.json
	$(GOENV) go run ./harness/cmd/reduce_trace --schedule schedules/generated/exec_m10_parent_amount_dedup.json --profile profiles/idempotent-replay.yaml --output results/raw/reduced_exec_m10.json --report results/raw/reduced_exec_m10.report.json
	$(GOENV) go run ./harness/cmd/reduce_trace --schedule schedules/generated/exec_m11_provider_key_drift.json --profile profiles/idempotent-replay.yaml --output results/raw/reduced_exec_m11.json --report results/raw/reduced_exec_m11.report.json

results/raw/bridge_results.json: check-spec-all $(MUTANT_RESULTS)
	$(PYENV) python3 analysis/make_bridge_results.py --modelcheck-dir modelcheck/raw --runs-dir results/raw --output $@

replay-formal-counterexamples: bootstrap results/raw/bridge_results.json
	$(PYENV) python3 analysis/validate_campaign.py --modelcheck-dir modelcheck/raw --runs-dir results/raw --bridge-path results/raw/bridge_results.json --skip-modelcheck

validate-campaign:
	$(PYENV) python3 analysis/validate_campaign.py --modelcheck-dir modelcheck/raw --runs-dir results/raw --bridge-path results/raw/bridge_results.json

normalize-results:
	$(PYENV) python3 analysis/normalize_results.py --runs-dir results/raw --modelcheck-dir modelcheck/raw --out-dir results/normalized

public-artifact-acceptance: clean-results lint test check-spec-all test-references safe-pairs test-mutants test-determinism test-reductions replay-formal-counterexamples validate-campaign normalize-results
	$(PYENV) python3 scripts/check_public_repo.py
