#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Installed Bun integration, source pins, offline use and pure composition."""
import base64
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
from urllib.parse import unquote, urlsplit
import os
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parent.parent
system = subprocess.check_output(['nix','eval','--impure','--raw','--expr','builtins.currentSystem'], text=True).strip()
# Archive the Git-aware checkout: metadata can describe an unrealized source
# on a cold store, and raw path: also admits untracked generated artifacts.
source_reference = 'git+file://' + str(root)
original_lock = (root/'flake.lock').read_bytes()
archived = json.loads(subprocess.check_output([
    'nix','flake','archive','--json','--no-update-lock-file',source_reference,
], text=True))
snapshot = archived['path']
source_path = Path(snapshot)
assert source_path.is_dir(), f'archived source is not materialized: {snapshot}'
assert source_path.resolve(strict=True) == source_path, f'noncanonical source: {snapshot}'
assert (source_path/'flake.lock').read_bytes() == original_lock
assert (root/'flake.lock').read_bytes() == original_lock
source_info = json.loads(subprocess.check_output(['nix','path-info','--json',snapshot],text=True))
receipt_dir = Path(os.environ.get('BUN_COMPOSITION_RECEIPTS', 'composition-receipts'))
receipt_dir.mkdir(parents=True,exist_ok=True)
(receipt_dir/'source.json').write_text(json.dumps({
    'reference':source_reference,
    'revision':subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip(),
    'archive':archived,
    'materializedSource':source_info,
},indent=2)+'\n')
with tempfile.TemporaryDirectory(prefix='bun-native-composition-') as temporary:
    temporary = Path(temporary)
    subprocess.run(['nix-store','--add-root',str(temporary/'source'),'--realise',snapshot],check=True)
    cli = Path(subprocess.check_output(['nix','build',str(root)+'#bun-purifier','--out-link',str(temporary/'cli'),'--print-out-paths'],text=True).strip())/'bin/bun-purifier'
    env = dict(os.environ, BUN_COMPOSITION_FLAKE=snapshot)
    env.update(NO_COLOR='1')
    env.pop('FORCE_COLOR',None)
    sdk = Path(subprocess.check_output(['nix','build','--impure','--expr',
        'let f=builtins.getFlake ("path:"+builtins.getEnv "BUN_COMPOSITION_FLAKE"); in f.inputs.nixpkgs.legacyPackages.'+system+'.bun',
        '--out-link',str(temporary/'sdk'),'--print-out-paths'],env=env,text=True).strip())
    # Supply the fixture's chosen runtime as the caller, not through the CLI.
    env['PATH'] = str(sdk/'bin') + os.pathsep + env.get('PATH', '')
    project = temporary/'project'
    project.mkdir()
    manifest = {'name':'bun-composed','version':'1.0.0','license':'MIT','main':'index.js','dependencies':{'@fixture/lib':'>=99'},
                'scripts':{'test':'bun -e \'const odd=require("@fixture/lib");if(!odd(3)||odd(4))process.exit(1)\''}}
    manifest['scripts']['plain-output'] = "bun -e 'process.stdout.write(\"pure-output\")'"
    original = json.dumps(manifest).encode()
    (project/'package.json').write_bytes(original)
    (project/'index.js').write_text('module.exports = require("@fixture/lib");\n')
    def run(*args,**kwargs):
        return subprocess.run([str(arg) for arg in args],cwd=project,env=env,check=True,**kwargs)
    reference = 'path:'+snapshot+'#checks.'+system+'.composition-producer'
    run(cli,'lock','--input',reference)
    lockfile = project/'bun-purifier.lock.json'
    data = json.loads(lockfile.read_text())
    assert len(data['projectInputs']) == 1
    assert not data['cachePaths'] and not data['gitHashes'] and not data['notInstalled']
    before = lockfile.read_bytes(), (project/'bun.lock').read_bytes()
    saved_native = json.loads(before[1])
    assert saved_native['packages'] == {}, saved_native
    assert saved_native['workspaces']['']['dependencies'] == manifest['dependencies']
    assert b'/nix/store/' not in before[1] and b'-nix.' not in before[1]
    run(cli,'lock')
    assert before == (lockfile.read_bytes(), (project/'bun.lock').read_bytes())
    run(cli,'prefetch')
    run(cli.parent/'bun','install','--frozen-lockfile')
    run(cli.parent/'bun','run','test')
    output = run(cli.parent/'bun','run','plain-output',capture_output=True,text=True)
    assert output.stdout == 'pure-output'
    run(sdk/'bin/bun','-e','const odd=require("@fixture/lib");if(!odd(3)||odd(4))process.exit(1)')
    assert (project/'package.json').read_bytes() == original
    assert before == (lockfile.read_bytes(), (project/'bun.lock').read_bytes())
    expression = temporary/'consumer.nix'
    expression.write_text('''{ source, project }:
      let f=builtins.getFlake ("path:"+source);
          pkgs=import f.inputs.nixpkgs {system=builtins.currentSystem;overlays=[f.overlays.default];};
          result=pkgs.bun-purifier.buildBunProject {src = /. + project;};
      in assert pkgs.bun-purifier.bun-purifier.drvPath != "";
         assert result.fetches == []; result.tests
    ''')
    run('nix','build','--impure','--file',expression,'--argstr','source',snapshot,
        '--argstr','project',project,'--out-link',temporary/'pure')
    assert (project/'package.json').read_bytes() == original
    assert before == (lockfile.read_bytes(), (project/'bun.lock').read_bytes())
    publication = temporary/'publication.nix'
    publication.write_text(expression.read_text().replace('result.tests',
        'result.packages."bun-composed".projections.npm'))
    repository = Path(subprocess.check_output(['nix','build','--impure','--file',str(publication),
        '--argstr','source',snapshot,'--argstr','project',str(project),
        '--out-link',str(temporary/'publication'),'--print-out-paths'],text=True).strip())
    catalog = Path(subprocess.check_output(['nix','eval','--impure','--raw','--file',str(publication),
        '--argstr','source',snapshot,'--argstr','project',str(project),'catalog'],text=True).strip())
    modules = json.loads(catalog.read_text())['modules']
    provided = next(item for item in modules if item['name'] == '@fixture/lib')
    uploads = {provided['name']:(repository/provided['archive']).read_bytes()}
    put_names = []
    class Registry(BaseHTTPRequestHandler):
        def do_GET(self):
            route = unquote(urlsplit(self.path).path).lstrip('/')
            if route.startswith('tarballs/'):
                body = (repository/route).read_bytes()
            else:
                available = [item for item in modules if item['name'] == route and item['name'] in uploads]
                if not available:
                    self.send_error(404)
                    return
                versions = {item['version']:{**item['package'],'dist':{
                    'integrity':item['integrity'],'tarball':'http://'+self.headers['Host']+'/'+item['archive']}} for item in available}
                body = json.dumps({'name':route,'versions':versions,
                    'dist-tags':{'latest':available[0]['version']}}).encode()
            self.send_response(200)
            self.send_header('Content-Length',str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def do_PUT(self):
            document = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            put_names.append(document['name'])
            uploads[document['name']] = base64.b64decode(next(iter(document['_attachments'].values()))['data'])
            self.send_response(201)
            self.end_headers()
            self.wfile.write(b'{}')
        def log_message(self,*args): pass
    server = ThreadingHTTPServer(('127.0.0.1',0),Registry)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    url = 'http://127.0.0.1:'+str(server.server_port)+'/'
    env['NPM_CONFIG_TOKEN'] = 'local-fixture'
    try:
        run(cli,'publish','--registry',url,'--access','public')
        assert provided['name'] not in put_names
        for item in modules:
            assert uploads[item['name']] == (repository/item['archive']).read_bytes(),item['name']
        downstream = temporary/'ordinary'
        downstream.mkdir()
        (downstream/'package.json').write_text('{"name":"ordinary-bun-consumer","private":true}')
        version = next(item['version'] for item in modules if item['name'] == 'bun-composed')
        subprocess.run([str(sdk/'bin/bun'),'install','--registry',url,'--cache-dir',str(temporary/'ordinary-cache'),
            'bun-composed@'+version],cwd=downstream,env=env,check=True)
        subprocess.run([str(sdk/'bin/bun'),'-e','const odd=require("bun-composed");if(!odd(3)||odd(4))process.exit(1)'],
            cwd=downstream,env=env,check=True)
    finally:
        server.shutdown()
        server.server_close()
    assert before == (lockfile.read_bytes(), (project/'bun.lock').read_bytes())
    assert (project/'package.json').read_bytes() == original
    external = temporary/'external'
    external.mkdir()
    (external/'package.json').write_bytes(original)
    ordinary = {'lockfileVersion':2,'configVersion':1,
        'workspaces':{'':{'name':'bun-composed','dependencies':{'@fixture/lib':'>=99'}}},
        'packages':{'@fixture/lib':['@fixture/lib@99.0.0','https://invalid.example/old.tgz',{},'sha512-AAAA']}}
    native = json.dumps(ordinary).encode()
    (external/'bun.lock').write_bytes(native)
    external_expression = temporary/'external.nix'
    external_expression.write_text(expression.read_text().replace('src = /. + project;',
        'src = /. + project;dependencies=[f.checks.${builtins.currentSystem}.composition-producer];'))
    run('nix','build','--impure','--file',external_expression,'--argstr','source',snapshot,
        '--argstr','project',external,'--out-link',temporary/'external-pure')
    assert (external/'package.json').read_bytes() == original
    assert (external/'bun.lock').read_bytes() == native
    addition = temporary/'addition'
    addition.mkdir()
    (addition/'package.json').write_text('{"name":"local-addition","version":"1.0.0","main":"index.js"}')
    (addition/'index.js').write_text('module.exports = 42;')
    run(cli.parent/'bun','add','../addition')
    changed = json.loads((project/'package.json').read_text())
    assert changed['dependencies']['@fixture/lib'] == '>=99'
    assert changed['dependencies']['local-addition'].endswith('../addition')
    assert len(json.loads(lockfile.read_text())['projectInputs']) == 1
    run(cli.parent/'bun','run','test')
    run(sdk/'bin/bun','-e','if(require("local-addition")!==42)process.exit(1)')
    unpurified = temporary/'unpurified'
    unpurified.mkdir()
    fallback = subprocess.run([str(cli.parent/'bun'),'--version'],cwd=unpurified,env=env,
        text=True,capture_output=True,check=True)
    assert 'no lockfile' in fallback.stderr and 'impure' in fallback.stderr
    assert fallback.stdout.strip()
print('BUN NATIVE REPOSITORY COMPOSITION PASSED')
