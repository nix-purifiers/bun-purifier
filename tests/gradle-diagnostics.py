#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Print bounded Gradle daemon and JVM crash diagnostics after a failed build."""
import argparse
from pathlib import Path
import re
import sys


def report(path, limit=32768):
    head, tail = bytearray(), bytearray()
    total = 0
    environment = False
    with path.open('rb') as source:
        for line in source:
            if line.strip() == b'Environment Variables:':
                environment = True
                line = b'[environment section omitted]\n'
            elif environment:
                if line.strip():
                    continue
                environment = False
            # Some crash reporters omit the section heading.
            if re.match(rb'^\s*[A-Za-z_][A-Za-z_0-9]*=', line):
                continue
            total += len(line)
            take = min(len(line), limit // 2 - len(head))
            head.extend(line[:take])
            tail.extend(line[take:])
            if len(tail) > limit // 2:
                del tail[:-limit // 2]
    separator = b'\n[diagnostic middle truncated]\n' if total > limit else b''
    return bytes(head) + separator + bytes(tail)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('gradle-home', 'project', 'tmpdir'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    daemon = args.gradle_home / 'daemon'
    groups = (
        ('Gradle daemon', daemon.glob('*/daemon-*.out.log')),
        ('JVM crash', [*args.project.glob('hs_err_pid*.log'),
                       *args.tmpdir.glob('hs_err_pid*.log'),
                       *daemon.glob('*/hs_err_pid*.log')]),
    )
    found = False
    for kind, candidates in groups:
        files = sorted({p for p in candidates if p.is_file() and not p.is_symlink()},
                       key=lambda p: (p.stat().st_mtime_ns, str(p)))[-2:]
        for path in files:
            found = True
            print(f'== {kind}: {path.name} (at most 32 KiB; environment omitted)', flush=True)
            try:
                sys.stdout.buffer.write(report(path))
                sys.stdout.buffer.write(b'\n')
                sys.stdout.buffer.flush()
            except OSError as error:
                print(f'Could not read {path.name}: {error.strerror}', flush=True)
    if not found:
        print('No Gradle daemon or JVM crash reports found.', flush=True)


if __name__ == '__main__':
    main()
