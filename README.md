# Retry-Safe Payment Idempotency Artifact

This repository contains the sanitized research artifact for bounded formal
checking and executable conformance tests for retry-safe payment idempotency.
It includes the TLA+ specification, TLC configurations, synthetic schedules,
mock-provider profiles, deterministic Go and Java reference implementations,
mutant-triggering schedules, trace reduction tooling, and public result
validation scripts.

The repository intentionally excludes manuscript sources, PDFs, review prompts,
private delivery packages, local logs, generated archives, and credentials. It
uses only synthetic schedules and mock providers.

## Requirements

- Go 1.24 or newer.
- Python 3.11 or newer.
- Docker, used for Java reference runs and TLC execution.
- Network access for `make bootstrap` or the first TLC run, which downloads the
  pinned TLA+ tools JAR into `modelcheck/tools/`.

The TLA+ tools download is pinned to version 1.8.0 and verified with SHA-256:

```text
ab323b79802aedc3203b3f9af37c6aca3ed43f4e0225b36f2aa77b26de46c05f
```

## Reproduce the Public Artifact

Run all exported checks from the repository root:

```sh
make public-artifact-acceptance
```

This target performs the following work from a clean result directory:

- formats and compiles Go/Python sources;
- runs all Go unit tests;
- downloads and verifies the pinned TLC JAR when needed;
- reruns all safe and mutant TLC configurations;
- reruns safe Go and Java conformance references;
- reruns all eleven executable mutant schedules;
- reruns deterministic replay checks;
- regenerates all eleven reduced executable traces;
- validates the formal-to-executable bridge; and
- scans the repository for excluded private artifacts and credential patterns.

For a shorter formal smoke check:

```sh
make check-spec-smoke
```

## Repository Contents

- `spec/`: TLA+ modules.
- `modelcheck/configs/`: safe, witness, liveness, and mutant TLC configs.
- `modelcheck/scripts/run_tlc.py`: deterministic TLC runner and summary writer.
- `harness/`: executable schedule runner, observers, mock provider, and shrinker.
- `references/`: Go and Java reference implementations.
- `schedules/`: public safe schedules and generated mutant schedules.
- `profiles/`: synthetic provider profile definitions.
- `analysis/`: bridge, normalization, parity, and validation scripts.
- `results/`: selected normalized and reduced public result records.
- `scripts/check_public_repo.py`: release hygiene scanner.

## License Status

No public reuse license is included in this sanitized export. Treat the private
repository as source-available for review only unless a separate license is
added by the repository owner.
