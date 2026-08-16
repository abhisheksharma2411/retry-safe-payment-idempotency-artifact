#!/usr/bin/env python3
import argparse
import json
import pathlib
import sys


def summarize(path):
    data = json.loads(pathlib.Path(path).read_text())
    return {
        "passed": data["observer"]["passed"],
        "fingerprint": data["observer"]["property_fingerprint"],
        "responses": [response["status"] for response in data["responses"]],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--left", required=True)
    parser.add_argument("--right", required=True)
    args = parser.parse_args()

    left = summarize(args.left)
    right = summarize(args.right)
    if left["passed"] != right["passed"] or left["responses"] != right["responses"]:
        print(json.dumps({"left": left, "right": right}, indent=2))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
