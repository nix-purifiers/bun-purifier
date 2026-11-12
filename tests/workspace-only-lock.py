#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Capture a genuine workspace-only text lock with no registry downloads."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("cli", "bun", "work"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=False)
    root = work / "source"
    (root / "packages/child").mkdir(parents=True)
    (root / "package.json").write_text(json.dumps({
        "name": "workspace-only-lock", "version": "1.0.0", "private": True,
        "workspaces": ["packages/*"]}) + "\n")
    (root / "packages/child/package.json").write_text(json.dumps({
        "name": "workspace-only-child", "version": "1.0.0"}) + "\n")
    (root / "bunfig.toml").write_text("[install]\noffline = true\n")
    for name in ("home", "tmp", "caller-cache", "runtime-cache", "locks"):
        (work / name).mkdir()
    sentinel = work / "caller-cache/sentinel"
    sentinel.write_text("unchanged\n")
    environment = {**os.environ,
                   "PATH": str(args.bun.resolve().parent) + os.pathsep + os.environ["PATH"],
                   "HOME": str(work / "home"), "TMPDIR": str(work / "tmp"),
                   "XDG_CACHE_HOME": str(work / "runtime-cache"),
                   "BUN_INSTALL_CACHE_DIR": str(work / "caller-cache")}
    for name in ("BUN_PURIFIER_TOOL_LOCKFILE", "BUN_PURIFIER_LOCKFILE", "BUN_PURIFIER_CACHE"):
        environment.pop(name, None)

    def run(name, command):
        result = subprocess.run([str(value) for value in command], cwd=root,
                                env=environment, capture_output=True, timeout=30)
        (work / (name + ".stdout")).write_bytes(result.stdout)
        (work / (name + ".stderr")).write_bytes(result.stderr)
        assert result.returncode == 0, (name, result.returncode, result.stderr.decode(errors="replace"))

    run("generate", [args.bun, "install", "--offline", "--lockfile-only",
                     "--save-text-lockfile", "--ignore-scripts", "--no-progress"])
    manifest = (root / "package.json").read_bytes()
    source_lock = (root / "bun.lock").read_bytes()
    before = sorted((str(p.relative_to(work / "caller-cache")), p.read_bytes())
                    for p in (work / "caller-cache").rglob("*") if p.is_file())
    outside = work / "locks/bun.lock"
    facts = work / "locks/bun-purifier.lock.json"
    run("capture", [args.cli, "lock", "--tool-lockfile", outside, "--lockfile", facts])
    assert outside.is_file() and not facts.exists()
    assert (root / "package.json").read_bytes() == manifest
    assert (root / "bun.lock").read_bytes() == source_lock
    assert not (root / "bun.lockb").exists()
    assert before == sorted((str(p.relative_to(work / "caller-cache")), p.read_bytes())
                            for p in (work / "caller-cache").rglob("*") if p.is_file())
    run("validate", [args.bun, "-e",
        'const lock = Bun.JSONC.parse(await Bun.file(process.argv[1]).text()); '
        'if (Object.keys(lock.packages).length !== 1) throw Error("expected only the local workspace link");',
        outside])
    result = {"status": "passed", "scope": "Synthetic workspace-only capture, not a root with no Bun lock",
              "sourcePreserved": True, "callerInstallCachePreserved": True,
              "externalTextLockSha256": hashlib.sha256(outside.read_bytes()).hexdigest(),
              "supplementaryFactsNeeded": False}
    (work / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
