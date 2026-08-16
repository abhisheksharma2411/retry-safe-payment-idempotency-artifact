#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess
import sys


PROFILE_FILES = {
    "idempotent-replay": "profiles/idempotent-replay.yaml",
    "authoritative-lookup": "profiles/authoritative-lookup.yaml",
    "opaque-provider": "profiles/opaque-provider.yaml",
}


SOURCE_SCHEDULES = [
    "schedules/public/changed_payload_all_states.json",
    "schedules/public/unknown_outcome_lookup_provider.json",
    "schedules/public/unknown_outcome_opaque_provider.json",
    "schedules/public/two_equal_partial_refunds.json",
    "schedules/generated/exec_m1_effect_before_claim.json",
    "schedules/generated/exec_m2_unknown_as_rejected.json",
    "schedules/generated/exec_m3_non_atomic_claim.json",
    "schedules/generated/exec_m4_raw_key_only_scope.json",
    "schedules/generated/exec_m5_loser_calls_provider.json",
    "schedules/generated/exec_m8_no_projection_repair.json",
    "schedules/generated/exec_m11_provider_key_drift.json",
]


def run(cmd: list[str], cwd: pathlib.Path, env: dict[str, str] | None = None) -> None:
    print("+ " + " ".join(cmd), flush=True)
    proc = subprocess.run(cmd, cwd=cwd, env=env, text=True)
    if proc.returncode != 0:
        raise SystemExit(proc.returncode)


def observer_passed(path: pathlib.Path) -> bool:
    data = json.loads(path.read_text())
    return data.get("observer", {}).get("passed") is True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".")
    args = parser.parse_args()
    root = pathlib.Path(args.root).resolve()
    (root / "schedules/generated").mkdir(parents=True, exist_ok=True)
    (root / "results/raw").mkdir(parents=True, exist_ok=True)

    env = os.environ.copy()
    env.setdefault("GOCACHE", str(root / ".gocache"))
    env.setdefault("GOMODCACHE", str(root / ".gomodcache"))

    for idx, source_name in enumerate(SOURCE_SCHEDULES, 1):
        source_path = root / source_name
        schedule = json.loads(source_path.read_text())
        profile_name = schedule["profile"]
        if profile_name not in PROFILE_FILES:
            raise SystemExit(f"unknown profile {profile_name} in {source_name}")
        schedule["mutant_id"] = "safe"
        schedule["schedule_id"] = f"safe_pair_{idx:02d}_{source_path.stem}"
        for event in schedule.get("events", []):
            request = event.get("request")
            if request:
                request["request_id"] = f"{schedule['schedule_id']}_{request['request_id']}"
        generated_schedule = root / "schedules/generated" / f"{schedule['schedule_id']}.json"
        generated_schedule.write_text(json.dumps(schedule, indent=2) + "\n")
        profile_path = PROFILE_FILES[profile_name]

        go_out = root / "results/raw" / f"{schedule['schedule_id']}.go.json"
        java_out = root / "results/raw" / f"{schedule['schedule_id']}.java.json"
        run([
            "go", "run", "./harness/cmd/run_schedule",
            "--mode", "cooperative",
            "--implementation", "go-reserve-replay",
            "--schedule", str(generated_schedule.relative_to(root)),
            "--profile", profile_path,
            "--output", str(go_out.relative_to(root)),
        ], root, env)
        run([
            "docker", "run", "--rm",
            "-v", f"{root}:/work",
            "-w", "/work",
            "eclipse-temurin:21-jdk",
            "sh", "-lc",
            "mkdir -p tmpbin/java-query-reconcile && "
            "javac -d tmpbin/java-query-reconcile references/java-query-reconcile/src/Main.java && "
            f"java -cp tmpbin/java-query-reconcile Main --schedule {generated_schedule.relative_to(root)} "
            f"--profile {profile_path} --output {java_out.relative_to(root)}",
        ], root)
        for output in (go_out, java_out):
            if not observer_passed(output):
                raise SystemExit(f"safe-pair observer failed for {output.relative_to(root)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
