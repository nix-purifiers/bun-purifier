#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Exercise local adoption using a real non-store runtime and cached artifacts."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['installed', 'bun', 'cache', 'node', 'work']:
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=False)
    for name in ['host-bin', 'tmp', 'caller-cache', 'empty', 'source', 'locks', 'wrong']:
        (work / name).mkdir()
    host = work / 'host-bin/bun'
    shutil.copyfile(args.bun.resolve(), host)
    host.chmod(0o755)
    tools = args.installed.resolve() / 'bin'
    environment = {**os.environ, 'PATH': f'{tools}:{host.parent}:' + os.environ['PATH'],
                   'TMPDIR': str(work / 'tmp'), 'BUN_TMPDIR': str(work / 'tmp'),
                   'BUN_INSTALL_CACHE_DIR': str(work / 'caller-cache'),
                   'XDG_CACHE_HOME': str(work / 'caller-cache'),
                   'NIX_CONFIG': os.environ.get('NIX_CONFIG', '') + '\nmax-jobs = 1\ncores = 1\n'}

    def run(name, command, cwd=None, variables=None, expected=0):
        with (work / (name + '.stdout')).open('w') as out, (work / (name + '.stderr')).open('w') as err:
            process = subprocess.Popen([str(v) for v in command], cwd=cwd or work / 'empty',
                                       env={**environment, **(variables or {})},
                                       stdout=out, stderr=err, start_new_session=True)
            try:
                process.wait(timeout=30)
            except BaseException:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=5)
                raise
        assert process.returncode == expected, (name, (work / (name + '.stderr')).read_text())
        return (work / (name + '.stdout')).read_text()

    probe = 'console.log(JSON.stringify({version:Bun.version,executable:process.execPath,argv:process.argv,argv0:process.argv0}))'
    arguments = ['-e', probe, '--', 'argument with spaces', '', '--literal']
    direct = json.loads(run('direct', [host, *arguments]))
    facade = json.loads(run('facade', [tools / 'bun', *arguments]))
    assert direct == facade and direct['executable'] == str(host)
    source, locks = work / 'source', work / 'locks'
    manifest = source / 'package.json'
    manifest.write_text(json.dumps({'name': 'local-host-replay', 'version': '1.0.0',
        'dependencies': {'kleur': '4.1.5'}, 'scripts': {'probe': 'bun -e \'console.log(JSON.stringify({version:Bun.version,executable:process.execPath,dependency:require("kleur/package.json").version}))\''}}, indent=2) + '\n')
    original = manifest.read_bytes()
    lockenv = {'BUN_PURIFIER_TOOL_LOCKFILE': str(locks / 'bun.lock'),
               'BUN_PURIFIER_LOCKFILE': str(locks / 'bun-purifier.lock.json')}
    run('lock', [tools / 'bun-purifier', 'lock'], source, lockenv)
    before_lock = (locks / 'bun.lock').read_bytes()

    def cache_digest():
        result = hashlib.sha256()
        for path in sorted((work / 'caller-cache').rglob('*')):
            result.update(str(path.relative_to(work / 'caller-cache')).encode())
            if path.is_file():
                result.update(path.read_bytes())
        return result.hexdigest()

    before_cache = cache_digest()
    replay = {**lockenv, 'BUN_PURIFIER_CACHE': str(args.cache.resolve())}
    run('prefetch', [tools / 'bun-purifier', 'prefetch'], source, replay)
    development = json.loads(run('development', [tools / 'bun', 'run', 'probe'], source, replay).strip().splitlines()[-1])
    assert development == {'version': direct['version'], 'executable': str(host), 'dependency': '4.1.5'}
    assert cache_digest() == before_cache
    assert manifest.read_bytes() == original and not (source / 'bun.lock').exists()
    assert (locks / 'bun.lock').read_bytes() == before_lock
    run('missing', [tools / 'bun-purifier', '--help'], variables={'PATH': str(tools)}, expected=127)
    (work / 'wrong/bun').symlink_to(args.node.resolve())
    run('incompatible', [tools / 'bun-purifier', '--help'], variables={'PATH': f'{tools}:{work / "wrong"}:{host.parent}'}, expected=1)
    assert 'must provide Bun.version' in (work / 'incompatible.stderr').read_text()
    result = {'status': 'passed', 'scope': 'local workflow only; no pure-build compatibility claim',
              'hostRuntime': direct, 'development': development,
              'runtimeSource': str(args.bun.resolve()), 'sourceManifestUnchanged': True,
              'externalBunLockUnchangedAfterReplay': True, 'callerCacheUntouched': True,
              'missingRuntimeRejected': True, 'incompatibleRuntimeRejectedWithoutFallback': True}
    (work / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
