"""Distinct source directories remain distinct artifacts despite equal names."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile

parser = argparse.ArgumentParser(description=__doc__)
for name in ('bun', 'project', 'packs', 'root-tar', 'public-tar', 'root-bin', 'public-bin', 'work'):
    parser.add_argument('--' + name, type=Path, required=True)
a = parser.parse_args()
a.work.mkdir()
for name in ('home', 'cache', 'tmp'):
    (a.work / name).mkdir()
env = {**os.environ, 'HOME': str(a.work / 'home'), 'TMPDIR': str(a.work / 'tmp'),
       'BUN_INSTALL_CACHE_DIR': str(a.work / 'cache')}
assert a.root_tar.resolve() != a.public_tar.resolve()
assert len(list(a.packs.rglob('*.tgz'))) == 2
records = []
for label, relative, archive, executable, expected in (
    ('root', '', a.root_tar, a.root_bin, 'private-root'),
    ('workspace', 'packages/public', a.public_tar, a.public_bin, 'public-workspace'),
):
    original = (a.project / relative / 'package.json').read_bytes()
    with tarfile.open(archive) as package:
        manifest = json.loads(package.extractfile('package/package.json').read())
        assert manifest == json.loads(original)
        assert manifest['name'] == 'fixture-collision' and manifest['version'] == '1.0.0'
        assert bool(manifest.get('private', False)) == (label == 'root')
        assert package.extractfile('package/dist/index.js').read() == (a.project / relative / 'dist/index.js').read_bytes()
    assert subprocess.check_output([str(executable)], env=env, timeout=30).decode().strip() == expected
    consumer = a.work / (label + '-consumer')
    consumer.mkdir()
    (consumer / 'package.json').write_text(json.dumps({
        'name': 'ordinary-consumer', 'version': '1.0.0', 'private': True,
        'dependencies': {'fixture-collision': 'file:' + str(archive)},
    }))
    result = subprocess.run([str(a.bun), 'install', '--offline', '--ignore-scripts', '--no-progress',
                             '--backend=copyfile'], cwd=consumer, env=env, capture_output=True, timeout=30)
    assert result.returncode == 0, result.stderr.decode()
    actual = subprocess.check_output([str(a.bun), '--eval',
                                      "import { identity } from 'fixture-collision'; console.log(identity)"],
                                     cwd=consumer, env=env, timeout=30).decode().strip()
    assert actual == expected
    installed = json.loads((consumer / 'node_modules/fixture-collision/package.json').read_text())
    assert installed == manifest
    assert (a.project / relative / 'package.json').read_bytes() == original
    records.append({'sourcePath': relative, 'private': manifest.get('private', False),
                    'version': manifest['version'], 'identity': actual,
                    'tarSha256': hashlib.sha256(archive.read_bytes()).hexdigest()})
assert records[0]['tarSha256'] != records[1]['tarSha256']
print(json.dumps(records, sort_keys=True))
