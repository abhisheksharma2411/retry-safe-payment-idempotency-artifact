#!/usr/bin/env python3
import hashlib
import pathlib
import sys
import urllib.request


URL = "https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar"
SHA256 = "ab323b79802aedc3203b3f9af37c6aca3ed43f4e0225b36f2aa77b26de46c05f"
TARGET = pathlib.Path("modelcheck/tools/tla2tools.jar")


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    if TARGET.is_file() and sha256(TARGET) == SHA256:
        print(f"{TARGET}: verified")
        return 0
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    tmp = TARGET.with_suffix(".jar.tmp")
    print(f"downloading {URL}")
    urllib.request.urlretrieve(URL, tmp)
    actual = sha256(tmp)
    if actual != SHA256:
        tmp.unlink(missing_ok=True)
        print(f"unexpected tla2tools.jar SHA-256: {actual}", file=sys.stderr)
        return 1
    tmp.replace(TARGET)
    print(f"{TARGET}: downloaded and verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
