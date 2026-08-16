#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import time


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = ROOT / "spec" / "PaymentIdempotency.tla"
CONFIG_DIR = ROOT / "modelcheck" / "configs"
RAW_DIR = ROOT / "modelcheck" / "raw"
TOOLS_DIR = ROOT / "modelcheck" / "tools"
JAR = TOOLS_DIR / "tla2tools.jar"

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

MUTANT_CONFIGS = [
    "formal_m1",
    "formal_m2",
    "formal_m3",
    "formal_m4",
    "formal_m5",
    "formal_m6",
    "formal_m7",
    "formal_m8",
    "formal_m9",
    "formal_m10",
    "formal_m11",
]

WITNESS_CONFIGS = [
    "opaque_impossibility_witness",
    "witness_successful_completion",
    "witness_final_rejection",
    "witness_changed_payload_reuse",
    "witness_concurrent_same_identity_retry",
    "witness_distinct_identities_with_the_same_raw_key",
    "witness_unknown_provider_outcome",
    "witness_provider_lookup_recovery",
    "witness_provider_replay_recovery",
    "witness_business_projection_mismatch",
    "witness_local_expiry",
    "witness_provider_expiry",
    "witness_two_legitimate_equal_partial_refunds",
]

LIVENESS_CONFIGS = [
    "liveness_fair",
    "liveness_no_recovery_fair",
]

EXPECTED_RESULTS = {name: "holds_within_bound" for name in SAFE_CONFIGS}
EXPECTED_RESULTS.update({name: "violated" for name in MUTANT_CONFIGS})
EXPECTED_RESULTS.update({name: "violated" for name in WITNESS_CONFIGS})
EXPECTED_RESULTS.update({"liveness_fair": "holds_within_bound"})
EXPECTED_RESULTS.update({"liveness_no_recovery_fair": "violated"})


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_log(log_text: str) -> dict:
    generated_matches = re.findall(r"([\d,]+) states generated", log_text)
    distinct_matches = re.findall(r"([\d,]+) distinct states found", log_text)
    depth = re.search(r"The depth of the complete state graph search is (\d+)", log_text)
    result = "holds_within_bound"
    if "is violated" in log_text or "was violated" in log_text:
        result = "violated"
    if "Error:" in log_text and result != "violated":
        result = "tool_error"
    generated = generated_matches[-1].replace(",", "") if generated_matches else "0"
    distinct = distinct_matches[-1].replace(",", "") if distinct_matches else "0"
    return {
        "generated_states": int(generated),
        "distinct_states": int(distinct),
        "search_depth": int(depth.group(1)) if depth else 0,
        "result": result,
    }


def run_config(name: str) -> dict:
    if not JAR.exists():
        raise FileNotFoundError(f"missing TLC jar at {JAR}")
    cfg = CONFIG_DIR / f"{name}.cfg"
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    log_path = RAW_DIR / f"{name}.log"
    start = time.time()
    if os.environ.get("T8_TLC_DOCKER", "") == "1":
        cmd = [
            "docker",
            "run",
            "--rm",
            "-v",
            f"{ROOT}:/work",
            "-w",
            "/work",
            "eclipse-temurin:21-jdk",
            "java",
            "-cp",
            "/work/modelcheck/tools/tla2tools.jar",
            "tlc2.TLC",
            "-cleanup",
            "-deadlock",
            "-config",
            f"/work/modelcheck/configs/{name}.cfg",
            "/work/spec/PaymentIdempotency.tla",
        ]
    else:
        cmd = [
            "java",
            "-cp",
            str(JAR),
            "tlc2.TLC",
            "-cleanup",
            "-deadlock",
            "-config",
            str(cfg),
            str(SPEC),
        ]
    proc = subprocess.run(cmd, cwd=ROOT, text=True, capture_output=True)
    wall_time = time.time() - start
    log_text = proc.stdout + "\n" + proc.stderr
    log_path.write_text(log_text)
    parsed = parse_log(log_text)
    summary = {
        "run_id": name,
        "model_variant": "payment_idempotency",
        "configuration": name,
        "properties": ["TypeOK", "P1", "P2", "P3", "P4", "P5", "P6", "P7"],
        "constants": {"config": name},
        "workers": 1,
        "generated_states": parsed["generated_states"],
        "distinct_states": parsed["distinct_states"],
        "search_depth": parsed["search_depth"],
        "wall_time_seconds": round(wall_time, 3),
        "peak_memory_mb": 0,
        "result": parsed["result"],
        "counterexample_path": None,
        "raw_log_sha256": sha256(log_path),
    }
    (RAW_DIR / f"{name}.summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    expected = EXPECTED_RESULTS[name]
    if summary["result"] != expected:
        raise RuntimeError(f"{name}: expected {expected}, got {summary['result']}")
    allowed_returncodes = (0, 12, 13) if summary["result"] == "violated" else (0,)
    if parsed["result"] == "tool_error" or proc.returncode not in allowed_returncodes:
        raise RuntimeError(f"{name}: TLC tool failed with exit code {proc.returncode}")
    return summary


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--all", action="store_true")
    args = parser.parse_args()

    configs = SAFE_CONFIGS[:2] if args.smoke else SAFE_CONFIGS + WITNESS_CONFIGS + MUTANT_CONFIGS + LIVENESS_CONFIGS
    summaries = []
    for config in configs:
        summaries.append(run_config(config))
    print(json.dumps(summaries, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(exc, file=sys.stderr)
        raise
