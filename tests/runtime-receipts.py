#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Execute the runtime checks and retain their Nix derivation/output identities."""
import json
from pathlib import Path
import subprocess


def capture(*args):
    return subprocess.check_output(args, text=True)


subprocess.run(['git', 'diff', '--quiet', 'HEAD'], check=True)
root = Path('runtime-receipts')
root.mkdir(exist_ok=True)
system = capture('nix', 'eval', '--impure', '--raw', '--expr', 'builtins.currentSystem')
checks = ['unit', 'elysia', 'conformance-offline']
checks += ['current-stable-runtime', 'current-stable-sources-program', 'current-stable-conformance-rebuild'] + ['current-stable-' + name for name in checks]
metadata = {
    'source': capture('git', 'rev-parse', 'HEAD').strip(),
    'system': system,
    'machine': capture('uname', '-m').strip(),
    'defaultBun': capture('nix', 'run', '.#bun-purifier.bun', '--', '--version').strip(),
}
(root / 'identity.json').write_text(json.dumps(metadata, indent=2) + '\n')
for check in checks:
    attr = f'.#checks.{system}.{check}'
    # flake check has already realized each output. Rebuild executes the
    # named check again instead of collecting a cached result as runtime proof.
    builds = json.loads(capture('nix', 'build', '--no-link', '--rebuild', '--option', 'max-jobs', '2', '--option', 'cores', '2', '-L', '--json', attr))
    paths = [path for build in builds for path in build['outputs'].values()]
    record = {
        **metadata,
        'check': attr,
        'builds': builds,
        'derivations': json.loads(capture('nix', 'derivation', 'show', attr)),
        'outputs': json.loads(capture('nix', 'path-info', '--json', *paths)),
    }
    if check == 'current-stable-runtime':
        record['nativeRuntime'] = json.loads(Path(paths[0]).read_text())
    (root / (check + '.json')).write_text(json.dumps(record, indent=2) + '\n')
