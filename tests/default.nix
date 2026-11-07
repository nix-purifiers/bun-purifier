# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked packages. The checks named
# `conformance-*` are those of the nix-purifiers contract.
{
  # A package set with the flake's default overlay, which adds the scope
  # `bun-purifier`, and in it buildBunProject.
  pkgs,
  # The lock reader, as the flake publishes it: lib.bun-purifier.readLock.
  readLock,
  # The bun-purifier command.
  bun-purifier,
  # The sources of the real-world projects, pinned in
  # tests/dependencies/flake.lock.
  realWorld,
  # Cache names for URL dependencies can change between Bun releases.
  sourcesLockFile ? ./fixtures/sources/bun-purifier.lock.json,
}:
let
  inherit (pkgs) lib;

  build = pkgs.bun-purifier.buildBunProject;
  cli = lib.getExe bun-purifier;
  localNetworkBoundary = import ./sandbox-local-network.nix { inherit pkgs; };
  elysiaTestPatches = [
    ./patches/elysia-stream-cancellation.patch
  ]
  ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ ./patches/elysia-native-static-ports.patch ];

  # A workspace of two packages: a library with registry dependencies (one
  # scoped) and a test, and an app that depends on it through
  # `workspace:*` and bundles itself with `bun build`.
  workspace = build { src = ./fixtures/workspace; };

  # A single package with a GitHub dependency, a tarball URL dependency,
  # and esbuild, whose native binary comes from the optional dependency
  # for the build platform.
  sources = build {
    src = ./fixtures/sources;
    lockFile = sourcesLockFile;
  };

  # Local dependencies and a git dependency: a file: directory inside the
  # project, one outside it (so `src` is the directory above the project),
  # a local tarball, and a git+ssh: repository, which Nix fetches over
  # HTTPS.
  paths = build {
    src = ./fixtures/paths;
    root = "app";
  };

  # Packages from the default registry an .npmrc names and from a scoped
  # registry.
  registries = build { src = ./fixtures/registries; };

  # A project whose source holds only bun's own files, with bun.lock
  # pinning kleur 4.1.4: a packaging flake keeps the bun-purifier lockfile
  # beside it. `externalTool` replaces bun.lock with one outside the
  # source, which pins kleur 4.1.5, together with its bun-purifier lockfile.
  external = build {
    src = ./external/src;
    lockFile = ./external/bun-purifier.lock.json;
  };
  externalTool = build {
    src = ./external/src;
    lockFile = ./external/tool/bun-purifier.lock.json;
    bunLock = ./external/tool/bun.lock;
  };

  # Elysia, a bun web framework, at a pinned commit. Its build bundles with
  # tsup and esbuild and writes type declarations with tsc. Its `test`
  # script also installs from npm over the network, so `tests` runs the
  # type check of its tests, the same checking an editor's TypeScript
  # server does, and the `elysia` check below runs `bun test`.
  elysia = build {
    src = realWorld.elysia;
    lockFile = ./real-world/elysia/bun-purifier.lock.json;
    testScript = "test:types";
  };

  # The project derivation of a build, which every package refers to.
  projectOf = result: (lib.head (lib.attrValues result.packages)).project;

  # Runs an executable and compares its output.
  runs =
    name: executable: expected:
    pkgs.runCommand "test-${name}" { } ''
      actual=$(${executable})
      if [ "$actual" != ${lib.escapeShellArg expected} ]; then
        echo "expected: "${lib.escapeShellArg expected}
        echo "actual:   $actual"
        exit 1
      fi
      touch $out
    '';

  # Lockfiles broken the ways a developer breaks them, each a copy of the
  # sources fixture, whose lockfile records the cache path of a tarball
  # dependency: bun.lock changed after the lock, the path edited by hand, a
  # merge conflict, a truncated file, and the path missing with the digest
  # recomputed, as a bug in the lock would leave it.
  negativeLock =
    name:
    import ../nix/lib/lock.nix {
      lockFile = ./negative/${name}/bun-purifier.lock.json;
      root = ./negative/${name};
    };
  expectProblem =
    name: text:
    lib.assertMsg (builtins.any (lib.hasInfix text) (negativeLock name).problems) "the problems of tests/negative/${name} do not mention: ${text}";
  buildFails = name: !(builtins.tryEval (build { src = ./negative/${name}; }).fetches).success;

  # Runs a bun-purifier command in a copy of a negative fixture, expects it
  # to fail before it needs Nix or the network, and checks that its error
  # says `expected`.
  commandFails =
    name: command: expected:
    pkgs.runCommand "test-${name}-${command}" { } ''
      export HOME=$TMPDIR
      cp -r ${./negative}/${name} project
      chmod -R u+w project
      cd project
      if ${cli} ${command} 2> err; then
        echo "bun-purifier ${command} succeeded on tests/negative/${name}"
        exit 1
      fi
      cat err
      grep -F -- ${lib.escapeShellArg expected} err
      touch $out
    '';

  # Two builds of a project that differ only in a variable the build never
  # reads, so Nix builds both.
  rebuilt = drv: drv.overrideAttrs { BUN_PURIFIER_REBUILD = "second"; };
  sameBuild =
    name: drv:
    pkgs.runCommand "test-rebuild-${name}" { nativeBuildInputs = [ pkgs.diffutils ]; } ''
      diff -r --no-dereference ${drv} ${rebuilt drv}
      diff -r ${drv.packs} ${(rebuilt drv).packs}
      touch $out
    '';

  marker = name: pkgs.runCommand "test-${name}" { } "touch $out";

  # A check that passes when every one of `checks` builds.
  allOf = name: checks: pkgs.runCommand "test-${name}" { inherit checks; } "touch $out";
in
{
  sandbox-local-network = localNetworkBoundary;
  browser-projections = import ./browser-projections.nix {
    inherit pkgs;
    build = build;
  };
  composition-producer = workspace.packages."@fixture/lib";
  npm-projection =
    pkgs.runCommand "bun-npm-projection-check"
      {
        __darwinAllowLocalNetworking = pkgs.stdenv.hostPlatform.isDarwin;
        networkBoundary = localNetworkBoundary;
        nativeBuildInputs = [
          pkgs.nodejs
          pkgs.python3
        ];
      }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        python ${./npm-projection.py} ${workspace.packages."@fixture/lib".projections.npm} \
          ${workspace.packages."@fixture/lib".projections.npm.catalog} ${pkgs.nodejs}/bin
        touch "$out"
      '';

  # The unit tests of the lock (tests/unit).
  unit =
    pkgs.runCommand "test-unit"
      {
        nativeBuildInputs = [ pkgs.bun ];
        src = lib.fileset.toSource {
          root = ../.;
          fileset = lib.fileset.unions [
            ../src
            ./unit
          ];
        };
      }
      ''
        export HOME=$TMPDIR
        cp -r $src/. .
        bun test ./tests/unit
        touch $out
      '';

  workspace-program =
    runs "workspace-program" workspace.packages.fixture-app.executables.fixture-app
      "3 is odd: true";
  workspace-tests = workspace.tests;
  # The built project, which `nix build --rebuild` repeats in CI
  # (tests/cli.sh rebuild).
  workspace-project = projectOf workspace;

  # A package written for callPackage takes the scope by name, as a
  # package in an overlay does, and gets the same build.
  builder-by-callpackage =
    let
      withPackage = pkgs.extend (
        final: prev: {
          example = final.callPackage (
            { bun-purifier }:
            (bun-purifier.buildBunProject { src = ./fixtures/workspace; }).packages.fixture-app
          ) { };
        }
      );
    in
    assert withPackage.example.drvPath == workspace.packages.fixture-app.drvPath;
    marker "builder-by-callpackage";

  # buildBunProject.override replaces what the builder takes from the
  # scope: here the bun the project builds with.
  builder-override =
    let
      markerBun = pkgs.runCommand "marker-bun" { passthru.version = pkgs.bun.version; } "mkdir $out";
      overridden = (pkgs.bun-purifier.buildBunProject.override { bun = markerBun; }) {
        src = ./fixtures/workspace;
      };
    in
    assert builtins.elem markerBun.drvPath (
      map (d: d.drvPath) (projectOf overridden).nativeBuildInputs
    );
    marker "builder-override";

  # bun-purifier.overrideScope replaces what everything in the scope
  # shares: here the bun, which the builder takes by name.
  scope-override =
    let
      markerBun = pkgs.runCommand "marker-bun" { passthru.version = pkgs.bun.version; } "mkdir $out";
      overridden = pkgs.bun-purifier.overrideScope (_: _: { bun = markerBun; });
      built = overridden.buildBunProject { src = ./fixtures/workspace; };
    in
    assert builtins.elem markerBun.drvPath (map (d: d.drvPath) (projectOf built).nativeBuildInputs);
    marker "scope-override";

  # The builder is an attribute of the scope `pkgs.bun-purifier`, beside
  # the command.
  builder-in-the-scope =
    assert !(pkgs ? buildBunProject);
    assert pkgs.bun-purifier ? buildBunProject && pkgs.bun-purifier ? bun-purifier;
    marker "builder-in-the-scope";

  sources-program =
    runs "sources-program" sources.packages.fixture-sources.executables.fixture-sources
      "plain object: true, one day: 86400000 ms";

  paths-program =
    runs "paths-program" paths.packages.fixture-paths.executables.fixture-paths
      "shared vendored packed plain:true";

  registries-program =
    runs "registries-program" registries.packages.fixture-registries.executables.fixture-registries
      "number: true";

  # The packed app names its workspace dependency by version, as the
  # registry needs it.
  workspace-release =
    pkgs.runCommand "test-workspace-release"
      {
        nativeBuildInputs = [
          pkgs.gnutar
          pkgs.gzip
          pkgs.jq
        ];
      }
      ''
        tar -xzf ${workspace.release.fixture-app.tarball} package/package.json
        dep=$(jq -r '.dependencies."@fixture/lib"' package/package.json)
        if [ "$dep" != "0.1.0" ]; then
          echo "@fixture/lib is \"$dep\" in the packed package.json"
          exit 1
        fi
        test -f ${workspace.release."@fixture/lib".tarball}
        touch $out
      '';

  # readLock gives the lock in the shape of the contract. esbuild's binary
  # for each system carries that system, and the outputs name the package.
  read-lock =
    let
      lock = readLock { src = ./fixtures/sources; };
      systemsOf =
        path: (lib.findFirst (e: e.path == path) (throw "no entry ${path}") lock.entries).systems or null;
    in
    assert lock.purifier == "bun-purifier";
    assert lock.problems == [ ];
    assert systemsOf "@esbuild/linux-x64@0.25.0@@@1" == [ "x86_64-linux" ];
    assert systemsOf "@esbuild/linux-arm64@0.25.0@@@1" == [ "aarch64-linux" ];
    assert systemsOf "@esbuild/darwin-arm64@0.25.0@@@1" == [ "aarch64-darwin" ];
    assert systemsOf "esbuild@0.25.0@@@1" == null;
    assert lib.assertMsg (
      !(builtins.any (e: lib.hasPrefix "@esbuild/darwin-x64" e.path) lock.entries)
    ) "readLock kept an entry no system installs";
    assert lock.outputs.fixture-sources.version == "1.0.0";
    marker "read-lock";

  # `fetches` lists the library entries of the build, by path.
  workspace-fetches =
    assert lib.assertMsg (
      map (e: e.path) workspace.fetches == [
        "@sindresorhus/is@4.6.0@@@1"
        "is-number@6.0.0@@@1"
        "is-odd@3.0.1@@@1"
        "kleur@4.1.5@@@1"
      ]
    ) "workspace.fetches lists other entries";
    marker "workspace-fetches";

  # `bun publish` sends the release tarball, as `bun-purifier publish`
  # runs it, to a registry in the sandbox, which receives the package with
  # that tarball attached.
  publish =
    pkgs.runCommand "test-publish"
      {
        __darwinAllowLocalNetworking = pkgs.stdenv.hostPlatform.isDarwin;
        networkBoundary = localNetworkBoundary;
        nativeBuildInputs = [
          pkgs.bun
          pkgs.jq
          pkgs.coreutils
          pkgs.diffutils
        ];
      }
      ''
        export HOME=$TMPDIR
        tarball=${workspace.release.fixture-app.tarball}
        bun ${./registry.ts} 4873 request.json &
        for i in $(seq 50); do
          (exec 3<>/dev/tcp/127.0.0.1/4873) 2>/dev/null && break
          sleep 0.1
        done
        # bun publish runs in the directory of the package, as the command
        # runs it, and wants the package manifest there.
        cp ${projectOf workspace}/packages/app/package.json .
        chmod u+w package.json
        NPM_CONFIG_TOKEN=test bun publish "$tarball" --registry http://127.0.0.1:4873/
        wait
        name=$(jq -r .name request.json)
        version=$(jq -r '.versions | keys[0]' request.json)
        if [ "$name" != fixture-app ] || [ "$version" != 1.0.0 ]; then
          echo "published $name $version"
          exit 1
        fi
        jq -r '._attachments[].data' request.json | base64 -d > sent.tgz
        cmp sent.tgz "$tarball"
        touch $out
      '';

  # Elysia builds, type-checks its tests, packs, and passes its own test
  # suite.
  elysia =
    pkgs.runCommand "test-elysia"
      {
        __darwinAllowLocalNetworking = pkgs.stdenv.hostPlatform.isDarwin;
        networkBoundary = localNetworkBoundary;
        nativeBuildInputs = [
          pkgs.bun
          pkgs.gnutar
          pkgs.gzip
        ];
        tests = elysia.tests;
        # Test-only synchronization and Darwin ephemeral-port patches preserve
        # the upstream assertions. Receipts list every applied patch.
        src = pkgs.applyPatches {
          name = "elysia-stream-test-synchronized";
          src = projectOf elysia;
          patches = elysiaTestPatches;
        };
        passthru = {
          upstreamSample = realWorld.elysia;
          samplePatch = ./patches/elysia-stream-cancellation.patch;
          samplePatches = elysiaTestPatches;
        };
      }
      ''
        export HOME=$TMPDIR
        tar -tzf ${elysia.release.elysia.tarball} | grep '^package/dist/index.mjs$' > /dev/null
        cp -r "$src" elysia
        chmod -R u+w elysia
        cd elysia
        bun test
        touch $out
      '';

  # A lockfile older than the project fails, in the Nix build and in the
  # command, naming `bun-purifier lock`.
  conformance-stale =
    assert expectProblem "stale" "changed since";
    assert expectProblem "stale" "Run `bun-purifier lock`";
    assert lib.assertMsg (buildFails "stale") "a stale lockfile did not stop the build";
    commandFails "stale" "prefetch" "Run `bun-purifier lock`";

  # A lockfile with a changed hash fails, naming `bun-purifier lock --force`.
  conformance-tampered =
    assert expectProblem "tampered" "edited after the lock";
    assert expectProblem "tampered" "bun-purifier lock --force";
    assert lib.assertMsg (buildFails "tampered") "a tampered lockfile did not stop the build";
    commandFails "tampered" "prefetch" "bun-purifier lock --force";

  # A lockfile without the cache path of a tarball dependency passes the
  # digest check and fails the build, naming `bun-purifier lock`.
  conformance-missing =
    assert expectProblem "missing-entry" "no cache path for the tarball dependency ms";
    assert expectProblem "missing-entry" "Run `bun-purifier lock`";
    assert lib.assertMsg (buildFails "missing-entry") "an incomplete lockfile did not stop the build";
    marker "conformance-missing";

  # A lockfile that is not valid fails, naming `bun-purifier lock --force`:
  # a merge conflict in the Nix build and the command, and a truncated file
  # in the command. A truncated file in the Nix build is a JSON error that
  # Nix cannot catch; its context names the same command, and
  # tests/cli.sh checks that message.
  conformance-malformed =
    assert expectProblem "conflicted" "merge conflict markers";
    assert expectProblem "conflicted" "bun-purifier lock --force";
    assert lib.assertMsg (buildFails "conflicted") "a conflicted lockfile did not stop the build";
    allOf "conformance-malformed" [
      (commandFails "conflicted" "prefetch" "bun-purifier lock --force")
      (commandFails "malformed" "prefetch" "not valid JSON. Run `bun-purifier lock --force`")
    ];

  # The relock itself needs the network, and the CI job of the same name
  # runs it (tests/cli.sh relock). Here `bun-purifier lock` finds every
  # lockfile current, so the command and the Nix library compute the same
  # digests of bun.lock, the manifests and the lockfile.
  conformance-relock = pkgs.runCommand "test-conformance-relock" { } ''
    export HOME=$TMPDIR
    cp -r ${./fixtures} fixtures
    cp -r ${./external} external
    chmod -R u+w fixtures external
    # The workspace fixture has no lockfile: bun.lock records everything.
    test ! -e fixtures/workspace/bun-purifier.lock.json
    for fixture in sources paths/app registries outdated; do
      (cd fixtures/$fixture && ${cli} lock) 2> out
      grep -q "is current" out || { cat out; exit 1; }
    done
    (cd external/src && ${cli} lock --lockfile ../bun-purifier.lock.json) 2> out
    grep -q "is current" out || { cat out; exit 1; }
    (cd external/src && ${cli} lock --lockfile ../tool/bun-purifier.lock.json --tool-lockfile ../tool/bun.lock) 2> out
    grep -q "is current" out || { cat out; exit 1; }
    touch $out
  '';

  # Two builds of the same fixtures give the same output.
  conformance-rebuild = allOf "conformance-rebuild" [
    (sameBuild "workspace" (projectOf workspace))
    (sameBuild "sources" (projectOf sources))
  ];

  # After `bun-purifier prefetch`, the everyday loop works in the sandbox,
  # which has no network: bun's own `bun install`, `bun run build`, the
  # app, and `bun test`. The command installs from the cache Nix built
  # (BUN_PURIFIER_CACHE), the cache `prefetch` builds with Nix outside the
  # sandbox; tests/cli.sh runs the whole command with the network cut.
  conformance-offline =
    pkgs.runCommand "test-conformance-offline"
      {
        nativeBuildInputs = [ pkgs.bun ];
        BUN_PURIFIER_CACHE = (projectOf workspace).cache;
      }
      ''
        export HOME=$TMPDIR
        cp -r ${./fixtures/workspace} project
        chmod -R u+w project
        cd project
        ${cli} prefetch
        # Reproduce Bun's Darwin install directory permissions on every SDK.
        # Keep cache directories and symlink targets untouched.
        find node_modules -path node_modules/.cache -prune -o -type d -exec chmod a-w {} +
        cd ..
        mkdir -p tests/fixtures
        cp -r ${./fixtures/workspace} tests/fixtures/workspace
        export OFFLINE_DIR="$PWD/project"
        export BUN_PURIFIER_TEST_CLI=${cli}
        export BUN_PURIFIER_TEST_BUN=${pkgs.bun}/bin/bun
        bash ${./cli.sh} offline-loop
        touch $out
      '';

  # A project whose source holds no bun-purifier lockfile builds from one
  # kept outside it, and also when bun.lock is replaced with one kept
  # outside it. Each build fetches the kleur its bun.lock pins.
  conformance-external =
    let
      fetchesKleur = result: version: builtins.any (e: e.path == "kleur@${version}@@@1") result.fetches;
    in
    assert fetchesKleur external "4.1.4" && !(fetchesKleur external "4.1.5");
    assert fetchesKleur externalTool "4.1.5" && !(fetchesKleur externalTool "4.1.4");
    allOf "conformance-external" [
      (runs "conformance-external-tree" external.packages.fixture-external.executables.fixture-external
        "built from a lockfile outside its source, 60000 ms"
      )
      (runs "conformance-external-tool"
        externalTool.packages.fixture-external.executables.fixture-external
        "built from a lockfile outside its source, 60000 ms"
      )
    ];
}
