#!/usr/bin/env python3
import argparse
import csv
import json
import pathlib


def load_jsons(paths):
    items = []
    for path in paths:
        data = json.loads(path.read_text())
        items.append(data)
    return items


def write_csv(path, rows, fieldnames):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs-dir", required=True)
    parser.add_argument("--modelcheck-dir", required=True)
    parser.add_argument("--out-dir", required=True)
    args = parser.parse_args()

    runs = []
    for path in sorted(pathlib.Path(args.runs_dir).glob("*.json")):
        data = json.loads(path.read_text())
        if "observer" in data and "responses" in data:
            data["source_file"] = path.name
            if data.get("mutant_id") == "safe":
                data["mutant_id"] = ""
            runs.append(data)
    modelchecks = load_jsons(sorted(pathlib.Path(args.modelcheck_dir).glob("*.summary.json")))
    out_dir = pathlib.Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    run_rows = []
    for run in runs:
        mutant_id = run.get("mutant_id", "")
        if mutant_id == "safe":
            mutant_id = ""
        run_rows.append(
            {
                "run_id": run["run_id"],
                "mode": run["mode"],
                "implementation": run["implementation"],
                "schedule_id": run["schedule_id"],
                "mutant_id": mutant_id,
                "observer_passed": run["observer"]["passed"],
                "property_fingerprint": run["observer"]["property_fingerprint"],
                "trace_events": len(run["trace"]),
                "provider_events": len(run["provider_ledger"]),
                "source_file": run.get("source_file", ""),
            }
        )
    write_csv(
        out_dir / "conformance_runs.csv",
        run_rows,
        ["run_id", "mode", "implementation", "schedule_id", "mutant_id", "observer_passed", "property_fingerprint", "trace_events", "provider_events", "source_file"],
    )

    model_rows = []
    for run in modelchecks:
        model_rows.append(
            {
                "run_id": run["run_id"],
                "variant": run["model_variant"],
                "configuration": run["configuration"],
                "result": run["result"],
                "generated_states": run["generated_states"],
                "distinct_states": run["distinct_states"],
                "depth": run["search_depth"],
                "wall_time_seconds": run["wall_time_seconds"],
            }
        )
    write_csv(
        out_dir / "modelcheck_runs.csv",
        model_rows,
        ["run_id", "variant", "configuration", "result", "generated_states", "distinct_states", "depth", "wall_time_seconds"],
    )

    (out_dir / "all_runs.json").write_text(json.dumps({"conformance": runs, "modelcheck": modelchecks}, indent=2) + "\n")


if __name__ == "__main__":
    main()
