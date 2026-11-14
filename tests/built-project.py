#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Check build-only output using its real generated tarball and strict source pack."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tarfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['built', 'rebuilt', 'fixture', 'bun', 'pack-helper', 'work', 'out']:
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir()
    for name in ['cache', 'runtime-cache', 'home', 'packs', 'consumer', 'strict-packs']:
        (work / name).mkdir()
    environment = {**os.environ, 'HOME': str(work / 'home'),
                   'BUN_INSTALL_CACHE_DIR': str(work / 'cache'),
                   'XDG_CACHE_HOME': str(work / 'runtime-cache')}

    def run(name, command, cwd, expected=0):
        result = subprocess.run([str(x) for x in command], cwd=cwd, env=environment,
                                capture_output=True, text=True, timeout=30)
        (work / (name + '.stdout')).write_text(result.stdout)
        (work / (name + '.stderr')).write_text(result.stderr)
        assert result.returncode == expected, (name, result.returncode, result.stderr)
        return result

    built, rebuilt = args.built.resolve(), args.rebuilt.resolve()
    assert built != rebuilt, 'the forced rebuild must have a distinct output'
    source_files = [p.relative_to(args.fixture) for p in args.fixture.rglob('*') if p.is_file()]
    for relative in source_files:
        expected = (args.fixture / relative).read_bytes()
        assert (built / relative).read_bytes() == (rebuilt / relative).read_bytes() == expected

    def inventory(root):
        result = {}
        for path in sorted(root.rglob('*')):
            relative = str(path.relative_to(root))
            if path.is_symlink():
                target = os.readlink(path)
                # Links into each output must resolve to that output's own tree.
                if root in [built, rebuilt] and path.name == 'private-common':
                    assert path.resolve() == root / 'lib'
                result[relative] = {'link': target.replace(str(root), '$OUTPUT')}
            elif path.is_file():
                result[relative] = {'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                                    'mode': stat.S_IMODE(path.stat().st_mode)}
        return result

    assert inventory(built) == inventory(rebuilt), 'forced rebuild changed built tree bytes or links'
    source_manifest = json.loads((built / 'package.json').read_text())
    generated = json.loads((built / 'dist/package.json').read_text())
    assert source_manifest['private'] is True
    assert 'version' not in json.loads((built / 'lib/package.json').read_text())
    assert generated['name'] == source_manifest['name']
    assert generated['version'] == source_manifest['version'] == '1.0.0'
    assert not generated.get('dependencies')
    probe = 'const {answer}=await import("./dist/index.js");if(answer!==42)throw Error("bad built artifact");console.log(answer)'
    assert run('built-import', [args.bun, '-e', probe], built).stdout.strip() == '42'
    assert run('rebuilt-import', [args.bun, '-e', probe], rebuilt).stdout.strip() == '42'
    # Bun 1.4.2 opens package.json for writing even for pack. Use a writable
    # copy of the actual built distribution, preserving and checking its bytes.
    distribution = work / 'distribution'
    shutil.copytree(built / 'dist', distribution)
    for path in [distribution, *distribution.rglob('*')]:
        if not path.is_symlink():
            path.chmod(path.stat().st_mode | stat.S_IWUSR)
    before_distribution = inventory(distribution)
    run('generated-pack', [args.bun, 'pm', 'pack', '--ignore-scripts', '--destination', work / 'packs'], distribution)
    assert inventory(distribution) == before_distribution
    tarballs = list((work / 'packs').glob('*.tgz'))
    assert len(tarballs) == 1
    with tarfile.open(tarballs[0]) as archive:
        assert json.load(archive.extractfile('package/package.json')) == generated
        assert archive.extractfile('package/index.js').read() == (built / 'dist/index.js').read_bytes()
    consumer = work / 'consumer'
    (consumer / 'package.json').write_text(json.dumps({'private': True, 'type': 'module',
        'dependencies': {generated['name']: 'file:' + str(tarballs[0])}}) + '\n')
    run('consumer-install', [args.bun, 'install', '--offline', '--ignore-scripts'], consumer)
    installed = consumer / 'node_modules' / generated['name']
    assert not installed.is_symlink()
    assert (installed / 'index.js').read_bytes() == (built / 'dist/index.js').read_bytes()
    assert run('consumer-import', [args.bun, '-e',
        'const {answer}=await import("fixture-private-native-app");if(answer!==42)throw Error("bad consumer");console.log(answer)'], consumer).stdout.strip() == '42'
    strict = work / 'strict-source'
    shutil.copytree(built, strict, symlinks=True)
    for path in [strict, *strict.rglob('*')]:
        if not path.is_symlink():
            path.chmod(path.stat().st_mode | stat.S_IWUSR)
    before = inventory(strict)
    negative = run('strict-source-pack', [args.bun, args.pack_helper, strict, '', work / 'strict-packs'], strict, expected=1)
    assert 'Failed to resolve workspace version' in negative.stderr
    assert '@fixture/private-common' in negative.stderr
    assert inventory(strict) == before
    result = {'status': 'passed', 'scope': 'synthetic build-only artifact; no upstream/cohort claim',
              'built': str(built), 'rebuilt': str(rebuilt), 'sourceFilesPreserved': len(source_files),
              'rebuiltTreeEqual': True, 'builtAnswer': 42, 'ordinaryTarballConsumerAnswer': 42,
              'strictSourcePackStillRejected': True, 'generatedManifest': generated,
              'tarballSha256': hashlib.sha256(tarballs[0].read_bytes()).hexdigest()}
    args.out.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
