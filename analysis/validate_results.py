#!/usr/bin/env python3
import argparse
import json
import pathlib
import sys


def require_keys(obj, keys, label):
    missing = [key for key in keys if key not in obj]
    if missing:
        raise ValueError(f"{label} missing keys: {missing}")


def validate_run(path: pathlib.Path) -> None:
    data = json.loads(path.read_text())
    require_keys(
        data,
        [
            "run_id",
            "mode",
            "implementation",
            "schedule_id",
            "profile",
            "trace",
            "responses",
            "records",
            "provider_ledger",
            "projection",
            "observer",
        ],
        path.name,
    )
    require_keys(data["observer"], ["passed", "properties", "property_fingerprint"], f"{path.name}.observer")
    for prop in data["observer"]["properties"]:
        require_keys(prop, ["name", "passed"], f"{path.name}.observer.properties")


def validate_modelcheck(path: pathlib.Path) -> None:
    data = json.loads(path.read_text())
    require_keys(
        data,
        [
            "run_id",
            "model_variant",
            "configuration",
            "properties",
            "constants",
            "workers",
            "generated_states",
            "distinct_states",
            "search_depth",
            "wall_time_seconds",
            "peak_memory_mb",
            "result",
            "raw_log_sha256",
        ],
        path.name,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="+")
    args = parser.parse_args()

    for raw_path in args.paths:
        path = pathlib.Path(raw_path)
        if "modelcheck" in path.parts:
            validate_modelcheck(path)
        else:
            validate_run(path)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(exc, file=sys.stderr)
        raise
