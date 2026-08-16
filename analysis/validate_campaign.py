#!/usr/bin/env python3
import argparse
import json
import pathlib
import sys


SAFE_CONFIGS = [
    "capture_minimal",
    "concurrent_same_identity",
    "cross_scope_same_raw_key",
    "changed_payload_all_states",
    "unknown_outcome_replay_provider",
    "unknown_outcome_lookup_provider",
    "unknown_outcome_opaque_provider",
    "local_and_provider_expiry",
    "partial_capture_and_refund",
    "reversal_parent_state",
    "projection_repair",
]

FORMAL_MUTANTS = [f"formal_m{i}" for i in range(1, 12)]
EXEC_MUTANTS = [f"exec_m{i}" for i in range(1, 12)]

SAFE_GO = [
    "changed_payload_all_states.go.json",
    "unknown_outcome_lookup_provider.go.json",
    "unknown_outcome_opaque_provider.go.json",
    "two_equal_partial_refunds.go.json",
]

SAFE_JAVA = [
    "changed_payload_all_states.java.json",
    "unknown_outcome_lookup_provider.java.json",
    "unknown_outcome_opaque_provider.java.json",
    "two_equal_partial_refunds.java.json",
]

EXEC_FILES = {
    "exec_m1": "exec_m1_effect_before_claim.go.json",
    "exec_m2": "exec_m2_unknown_as_rejected.go.json",
    "exec_m3": "exec_m3_non_atomic_claim.go.json",
    "exec_m4": "exec_m4_raw_key_only_scope.go.json",
    "exec_m5": "exec_m5_loser_calls_provider.go.json",
    "exec_m6": "exec_m6_late_payload_check.go.json",
    "exec_m7": "exec_m7_terminal_reexec.go.json",
    "exec_m8": "exec_m8_no_projection_repair.go.json",
    "exec_m9": "exec_m9_short_retention.go.json",
    "exec_m10": "exec_m10_parent_amount_dedup.go.json",
    "exec_m11": "exec_m11_provider_key_drift.go.json",
}


def load(path: pathlib.Path) -> dict:
    if not path.is_file():
        raise AssertionError(f"missing required result: {path}")
    return json.loads(path.read_text())


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def validate_modelcheck(modelcheck_dir: pathlib.Path) -> None:
    for name in SAFE_CONFIGS:
        data = load(modelcheck_dir / f"{name}.summary.json")
        require(data["result"] == "holds_within_bound", f"{name}: expected holds_within_bound, got {data['result']}")
        require(data["generated_states"] > 0 and data["distinct_states"] > 0, f"{name}: missing TLC state counts")
        require(data["raw_log_sha256"], f"{name}: missing raw log hash")
    witness = load(modelcheck_dir / "opaque_impossibility_witness.summary.json")
    require(witness["result"] == "violated", "opaque_impossibility_witness must violate P3")
    for name in FORMAL_MUTANTS:
        data = load(modelcheck_dir / f"{name}.summary.json")
        require(data["result"] == "violated", f"{name}: expected violated, got {data['result']}")
        require(data["generated_states"] > 0 and data["distinct_states"] > 0, f"{name}: missing TLC state counts")
        require(data["raw_log_sha256"], f"{name}: missing raw log hash")


def validate_runs(runs_dir: pathlib.Path) -> None:
    for filename in SAFE_GO + SAFE_JAVA:
        data = load(runs_dir / filename)
        require(data["observer"]["passed"] is True, f"{filename}: safe reference was rejected")
    for mutant_id, filename in EXEC_FILES.items():
        data = load(runs_dir / filename)
        require(data.get("mutant_id") == mutant_id, f"{filename}: expected mutant_id {mutant_id}, got {data.get('mutant_id')}")
        require(data["observer"]["passed"] is False, f"{filename}: mutant was not detected")
        failing = [prop["name"] for prop in data["observer"]["properties"] if not prop["passed"]]
        require(failing, f"{filename}: missing failing property")
    for i in range(1, 12):
        report = load(runs_dir / f"reduced_exec_m{i}.report.json")
        require(report["one_minimal"] is True, f"reduced_exec_m{i}: reduction is not 1-minimal")
        require(report["replay_count"] >= 0, f"reduced_exec_m{i}: missing replay count")
        require(report["reduced_events"] <= report["original_events"], f"reduced_exec_m{i}: reduction grew the trace")


def validate_bridge(path: pathlib.Path) -> None:
    bridge = load(path)
    require(bridge["mapped_cases"] == 11, f"expected 11 mapped bridge cases, got {bridge['mapped_cases']}")
    require(bridge["reproduced_cases"] == 11, f"expected 11 reproduced bridge cases, got {bridge['reproduced_cases']}")
    require(bridge["matching_classifications"] == 11, f"expected 11 matching bridge cases, got {bridge['matching_classifications']}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--modelcheck-dir", required=True)
    parser.add_argument("--runs-dir", required=True)
    parser.add_argument("--bridge-path", required=True)
    parser.add_argument("--skip-modelcheck", action="store_true")
    args = parser.parse_args()

    if not args.skip_modelcheck:
        validate_modelcheck(pathlib.Path(args.modelcheck_dir))
    validate_runs(pathlib.Path(args.runs_dir))
    validate_bridge(pathlib.Path(args.bridge_path))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"campaign validation failed: {exc}", file=sys.stderr)
        raise
