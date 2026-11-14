"""A genuine executable Bun binary lock survives script interpreter patching."""
import gzip
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile

phase, directory, bun = sys.argv[1:]
root = Path(directory)

def render():
    return subprocess.check_output([bun, '--no-install', str(root / 'bun.lockb')], cwd=root, timeout=30)

if phase == 'prepare':
    root.mkdir()
    (root / 'package.json').write_text(json.dumps({'name': 'binary-shebang-fixture', 'version': '1.0.0', 'dependencies': {'local-input': 'file:./input.tgz'}}))
    (root / 'bunfig.toml').write_text('[install]\nsaveTextLockfile = false\noffline = true\n')
    data = json.dumps({'name': 'local-input', 'version': '1.0.0'}).encode()
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive, mode='w') as output:
        entry = tarfile.TarInfo('package/package.json')
        entry.size, entry.mode = len(data), 0o644
        output.addfile(entry, io.BytesIO(data))
    (root / 'input.tgz').write_bytes(gzip.compress(archive.getvalue(), mtime=0))
    subprocess.run([bun, 'install', '--offline', '--lockfile-only', '--ignore-scripts'], cwd=root, check=True, timeout=30)
    lock = root / 'bun.lockb'
    assert lock.read_bytes().startswith(b'#!/usr/bin/env bun\n')
    lock.chmod(0o755)
    (root / 'expected.json').write_text(json.dumps({'lock': hashlib.sha256(lock.read_bytes()).hexdigest(), 'render': hashlib.sha256(render()).hexdigest()}))
    script = root / 'ordinary script'
    script.write_text('#!/usr/bin/env bun\nconsole.log(42)\n')
    script.chmod(0o755)
elif phase == 'verify':
    expected = json.loads((root / 'expected.json').read_text())
    lock = root / 'bun.lockb'
    assert hashlib.sha256(lock.read_bytes()).hexdigest() == expected['lock']
    assert lock.stat().st_mode & 0o777 == 0o755
    assert hashlib.sha256(render()).hexdigest() == expected['render']
    script = root / 'ordinary script'
    assert script.read_text().splitlines()[0] == '#!' + bun
    assert subprocess.check_output([str(script)], cwd=root, timeout=30).strip() == b'42'
else:
    raise ValueError(phase)
