#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Execute the runtime checks and retain their Nix derivation/output identities."""
import json
import hashlib
from pathlib import Path
import subprocess
import sys


def capture(*args):
    return subprocess.check_output(args, text=True)


subprocess.run(['git', 'diff', '--quiet', 'HEAD'], check=True)
root = Path('runtime-receipts')
root.mkdir(exist_ok=True)
configuration = json.loads(capture('nix', 'config', 'show', '--json', '--option', 'sandbox', 'true'))
sandbox = configuration['sandbox']['value']
if sandbox not in ('true', True):
    raise RuntimeError(f'pure runtime checks require sandbox=true, got {sandbox!r}')
system = capture('nix', 'eval', '--impure', '--raw', '--expr', 'builtins.currentSystem')
checks = ['unit', 'elysia', 'conformance-offline']
# Retain executable loopback/external-denial proof with the native artifacts.
boundary_check = 'sandbox-local-network'
checks += [boundary_check, 'current-stable-runtime', 'current-stable-sources-program', 'current-stable-conformance-rebuild'] + ['current-stable-' + name for name in checks]
metadata = {
    'source': capture('git', 'rev-parse', 'HEAD').strip(),
    'system': system,
    'sandbox': sandbox,
    'machine': capture('uname', '-m').strip(),
    'defaultBun': capture('nix', 'run', '.#bun-purifier.bun', '--', '--version').strip(),
}
(root / 'identity.json').write_text(json.dumps(metadata, indent=2) + '\n')
for check in checks:
    attr = f'.#checks.{system}.{check}'
    # flake check has already realized each output. Rebuild executes the
    # named check again instead of collecting a cached result as runtime proof.
    command = ['nix', 'build', '--no-link', '--rebuild', '--option', 'sandbox', 'true', '--option', 'max-jobs', '2', '--option', 'cores', '2', '-L', '--json', attr]
    try:
        executed = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, timeout=900)
    except subprocess.TimeoutExpired as error:
        (root / (check + '.json')).write_text(json.dumps({
            **metadata, 'check': attr, 'command': command, 'status': 'timeout',
            'timeoutSeconds': 900,
        }, indent=2) + '\n')
        (root / (check + '.log')).write_bytes(error.stderr or b'')
        raise
    (root / (check + '.log')).write_text(executed.stderr)
    print(executed.stderr, file=sys.stderr, end='')
    if executed.returncode:
        (root / (check + '.json')).write_text(json.dumps({
            **metadata, 'check': attr, 'command': command, 'status': 'failed',
            'returncode': executed.returncode,
        }, indent=2) + '\n')
        raise subprocess.CalledProcessError(executed.returncode, command)
    builds = json.loads(executed.stdout)
    paths = [path for build in builds for path in build['outputs'].values()]
    sample = None
    if check.endswith('elysia'):
        derivations = json.loads(capture('nix', 'derivation', 'show', attr))
        definitions = derivations.get('derivations', derivations)
        patched_source = next(value['env']['src'] for value in definitions.values()
                              if 'src' in value.get('env', {}))
        patch_paths = json.loads(capture('nix', 'eval', '--json', attr + '.samplePatches'))
        sample = {
            'repository': 'elysiajs/elysia',
            'upstreamRevision': 'e037eca710e7ad193be09cc6615ab0dbe54af914',
            'modified': True,
            'modification': 'test-only harness patches listed in patches',
            'patchSha256': hashlib.sha256(Path('tests/patches/elysia-stream-cancellation.patch').read_bytes()).hexdigest(),
            'patches': [{'path': path, 'sha256': hashlib.sha256(Path(path).read_bytes()).hexdigest()}
                        for path in patch_paths],
            'patchedSource': json.loads(capture('nix', 'path-info', '--json', patched_source)),
        }
    record = {
        **metadata,
        'check': attr,
        'command': command,
        'status': 'passed',
        'builds': builds,
        'derivations': json.loads(capture('nix', 'derivation', 'show', attr)),
        'outputs': json.loads(capture('nix', 'path-info', '--json', *paths)),
        'sample': sample,
    }
    if check == boundary_check:
        record['networkBoundary'] = json.loads(Path(paths[0]).read_text())
    if check == 'current-stable-runtime':
        record['nativeRuntime'] = json.loads(Path(paths[0]).read_text())
    (root / (check + '.json')).write_text(json.dumps(record, indent=2) + '\n')
