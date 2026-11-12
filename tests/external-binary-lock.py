#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""External text-lock capture must preserve the caller's binary source lock."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("cli", "bun", "work"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=False)
    for name in ("home", "tmp", "cache"):
        (work / name).mkdir()
    environment = {**os.environ, "PATH": str(args.bun.resolve().parent) + os.pathsep + os.environ["PATH"],
                   "HOME": str(work / "home"),
                   "TMPDIR": str(work / "tmp"), "XDG_CACHE_HOME": str(work / "cache"),
                   "BUN_INSTALL_CACHE_DIR": str(work / "cache")}
    for name in ("BUN_PURIFIER_TOOL_LOCKFILE", "BUN_PURIFIER_LOCKFILE", "BUN_PURIFIER_CACHE"):
        environment.pop(name, None)

    def run(name, command, root, expected=0):
        result = subprocess.run([str(value) for value in command], cwd=root,
                                env=environment, capture_output=True, timeout=30)
        (work / (name + ".stdout")).write_bytes(result.stdout)
        (work / (name + ".stderr")).write_bytes(result.stderr)
        assert result.returncode == expected, (name, result.returncode,
                                              result.stderr.decode(errors="replace"))
        return result

    fixture = work / "fixture"
    (fixture / "packages/child").mkdir(parents=True)
    (fixture / "package.json").write_text(json.dumps({
        "name": "binary-lock-fixture", "version": "1.0.0", "private": True,
        "workspaces": ["packages/*"]}) + "\n")
    (fixture / "packages/child/package.json").write_text(json.dumps({
        "name": "binary-lock-child", "version": "1.0.0"}) + "\n")
    (fixture / "bunfig.toml").write_text(
        "[install]\nsaveTextLockfile = false\noffline = true\n")
    run("generate", [args.bun, "install", "--offline", "--lockfile-only",
                     "--ignore-scripts", "--no-progress"], fixture)
    binary = (fixture / "bun.lockb").read_bytes()
    assert not (fixture / "bun.lock").exists()
    cases = []
    for name in ("regular", "storage-failure", "symlink", "absent"):
        root = work / name
        shutil.copytree(fixture, root)
        path = root / "bun.lockb"
        path.chmod(0o640)
        target = None
        if name == "symlink":
            target = work / "shared-binary"
            target.write_bytes(binary)
            target.chmod(0o440)
            path.unlink()
            path.symlink_to("../shared-binary")
        elif name == "absent":
            path.unlink()
        manifest = (root / "package.json").read_bytes()
        locks = work / (name + "-locks")
        locks.mkdir()
        outside = locks / "bun.lock"
        expected = 0
        if name == "storage-failure":
            blocker = locks / "not-a-directory"
            blocker.write_text("retained\n")
            outside = blocker / "bun.lock"
            expected = 1
        result = run(name, [args.cli, "lock", "--tool-lockfile", outside,
                           "--lockfile", locks / "bun-purifier.lock.json"], root,
                     expected=expected)
        assert (root / "package.json").read_bytes() == manifest
        assert not (root / "bun.lock").exists()
        if name == "symlink":
            assert path.is_symlink() and os.readlink(path) == "../shared-binary"
            assert target.read_bytes() == binary and stat.S_IMODE(target.stat().st_mode) == 0o440
        elif name == "absent":
            assert not path.exists() and not path.is_symlink()
        else:
            assert path.read_bytes() == binary
            assert stat.S_IMODE(path.stat().st_mode) == 0o640
        if expected == 0:
            assert outside.is_file()
            assert json.loads(outside.read_text())["workspaces"][""]["name"] == "binary-lock-fixture"
        else:
            assert b"EEXIST" in result.stderr or b"ENOTDIR" in result.stderr
            assert (locks / "not-a-directory").read_text() == "retained\n"
        cases.append({"case": name, "exitCode": expected, "sourcePreserved": True})
    proof = {"status": "passed", "scope": "Synthetic external binary-lock preservation only",
             "cli": str(args.cli), "bun": str(args.bun), "cases": cases,
             "generatedBinarySha256": hashlib.sha256(binary).hexdigest()}
    (work / "result.json").write_text(json.dumps(proof, indent=2) + "\n")
    print(json.dumps(proof, indent=2))


if __name__ == "__main__":
    main()
