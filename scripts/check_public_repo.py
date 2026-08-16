#!/usr/bin/env python3
import os
import pathlib
import re
import subprocess
import sys
from typing import Iterable, Optional


ROOT = pathlib.Path(__file__).resolve().parents[1]
FORBIDDEN_DIRS = {
    "paper",
    "FINAL_DELIVERY",
    "return_to_chatgpt",
    "dist",
    "codex",
    "review",
    "logs",
}
FORBIDDEN_SUFFIXES = {".pdf", ".tex", ".zip", ".jar", ".class", ".log"}
SKIP_DIRS = {
    ".git",
    ".gocache",
    ".gomodcache",
    ".pycache",
    "tmpbin",
    "modelcheck/tools",
}
PRIVATE_MARKERS = [
    "Abhishek" + ".Sharma",
    "abhicse" + "24",
    "GoogleDrive-" + "abhicse",
    "JJSS" + "RKJBJKJJ",
    "VISA " + "EB1A",
    "/Users/" + "Abhishek",
    "My Drive/" + "JJSS",
]
FORBIDDEN_PATH_MARKERS = [
    "../" + "cod" + "ex/",
    "cod" + "ex/",
    "lo" + "gs/",
]
SECRET_PATTERNS = [
    re.compile(r"gh[pousr]_[A-Za-z0-9_]{20,}"),
    re.compile(r"github_pat_[A-Za-z0-9_]{20,}"),
    re.compile(r"(?i)(api[_-]?key|token|secret|password)\s*[:=]\s*['\"][^'\"]{8,}['\"]"),
    re.compile(r"-----BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----"),
]


def git_files() -> Optional[list[pathlib.Path]]:
    if not (ROOT / ".git").exists():
        return None
    result = subprocess.run(
        ["git", "ls-files"],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        return None
    return [ROOT / line for line in result.stdout.splitlines() if line]


def skipped(rel: pathlib.Path) -> bool:
    rel_text = rel.as_posix()
    return any(rel_text == item or rel_text.startswith(item + "/") for item in SKIP_DIRS)


def walk_files() -> Iterable[pathlib.Path]:
    tracked = git_files()
    if tracked is not None:
        yield from tracked
        return
    for dirpath, dirnames, filenames in os.walk(ROOT):
        current = pathlib.Path(dirpath)
        rel_dir = current.relative_to(ROOT)
        dirnames[:] = [
            name
            for name in dirnames
            if not skipped((rel_dir / name) if rel_dir != pathlib.Path(".") else pathlib.Path(name))
        ]
        for filename in filenames:
            path = current / filename
            rel = path.relative_to(ROOT)
            if not skipped(rel):
                yield path


def read_text(path: pathlib.Path) -> str:
    data = path.read_bytes()
    if b"\0" in data:
        raise AssertionError(f"binary file is not allowed: {path.relative_to(ROOT)}")
    return data.decode("utf-8")


def check_path(path: pathlib.Path) -> list[str]:
    rel = path.relative_to(ROOT)
    parts = set(rel.parts)
    errors: list[str] = []
    if parts & FORBIDDEN_DIRS:
        errors.append(f"forbidden directory in export: {rel}")
    if rel.suffix in FORBIDDEN_SUFFIXES:
        errors.append(f"forbidden file type in export: {rel}")
    return errors


def check_text(path: pathlib.Path) -> list[str]:
    rel = path.relative_to(ROOT)
    errors: list[str] = []
    try:
        text = read_text(path)
    except UnicodeDecodeError as exc:
        return [f"non-UTF-8 text file is not allowed: {rel}: {exc}"]
    for marker in PRIVATE_MARKERS:
        if marker in text:
            errors.append(f"private marker found in {rel}")
    if rel.as_posix() not in {".gitignore", "scripts/check_public_repo.py"}:
        for marker in FORBIDDEN_PATH_MARKERS:
            if marker in text:
                errors.append(f"forbidden private path reference found in {rel}")
    for pattern in SECRET_PATTERNS:
        if pattern.search(text):
            errors.append(f"credential-like pattern found in {rel}")
    return errors


def main() -> int:
    errors: list[str] = []
    files = sorted(set(walk_files()))
    for path in files:
        if path.name == ".DS_Store":
            errors.append(f"macOS metadata file is not allowed: {path.relative_to(ROOT)}")
            continue
        errors.extend(check_path(path))
        if path.is_symlink():
            errors.append(f"symlink is not allowed in export: {path.relative_to(ROOT)}")
            continue
        errors.extend(check_text(path))
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print(f"public export check passed: {len(files)} files scanned")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
