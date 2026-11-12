# SPDX-License-Identifier: MIT
#
# buildBunProject: the sandboxed builds of a bun project, from bun.lock and
# the lockfile `bun-purifier lock` writes next to it.
#
# The file is a package for callPackage: the first argument set is what it
# takes from the package set, and the result is the builder. The
# bun-purifier overlay (`overlays.default`) adds the scope `bun-purifier`
# to the package set, and the scope holds the builder as `buildBunProject`
# (pkgs/default.nix). A package written for callPackage takes the scope:
#
#   { bun-purifier }: (bun-purifier.buildBunProject { src = ./.; }).packages.app
#
# `bun-purifier.buildBunProject.override` replaces what the builder takes,
# such as `bun`, and `bun-purifier.overrideScope` replaces what everything
# in the scope shares. The builder returns
#
#   packages.<name>   package <name>, built: its directory in the built
#                     project at `lib/node_modules/<name>`, and the
#                     executables of its `bin` field in `bin/`, run by bun.
#                     `executables.<bin>` is the path of each executable.
#   tests             the `testScript` of every package that has one, run
#                     in the sandbox on the built project
#   release.<name>    the tarball of package <name>, as `bun pm pack` makes
#                     it and `bun-purifier publish` uploads it. `tarball` is
#                     the path of the file.
#   fetches           the download entries of the lock (`entries` of
#                     readLock), for every system the nix-purifiers build
#                     for; an entry needed on only some carries `systems`
{
  lib,
  stdenvNoCC,
  runCommand,
  runtimeShell,
  # The bun that installs, builds, tests and runs the project.
  bun,
  # The fetchers of the download entries, unless `fetchers` replaces them.
  fetchurl,
  fetchgit,
  # What `fetchEntry` of the shared library unpacks archives with.
  unzip,
  zstd,
  python3,
  nodejs,
  nix,
  writeText,
  # The `purifier` library namespace of the shared nix-purifiers library.
  # The overlay passes the one of the bun-purifier flake.
  purifier,
}:
{
  # The source tree: the bun project, the directory of bun.lock, or a
  # directory above it that also holds the `file:` dependencies outside
  # the project.
  src,
  webAssets ? { },
  # The project inside `src`, as a relative path; "" when `src` is the
  # project.
  root ? "",
  # The lockfile, by default the one `bun-purifier lock` writes at the
  # project root. The lock writes no lockfile when bun.lock records
  # everything, and the build then reads bun.lock alone. An external
  # build, whose flake keeps the lockfiles outside the repository, passes
  # its copy here.
  lockFile ? (if root == "" then src else src + "/${root}") + "/bun-purifier.lock.json",
  # The project's bun.lock, by default the one at the project root. An
  # external build passes its copy here, and that copy replaces the one in
  # `src` for the build.
  bunLock ? (if root == "" then src else src + "/${root}") + "/bun.lock",
  # Fetchers in place of the package set's own, passed unchanged to
  # `fetchEntry` of the shared library: `fetchurl` for a registry mirror or
  # credentials, `fetchgit` for a private git repository.
  fetchers ? { },
  dependencies ? purifier.lockedProjectInputs {
    inputs =
      if builtins.pathExists lockFile then (lib.importJSON lockFile).projectInputs or [ ] else [ ];
    system = stdenvNoCC.hostPlatform.system;
  },
  # The package script that builds a package. Packages without it are
  # installed only.
  buildScript ? "build",
  # The package script `tests` runs.
  testScript ? "test",
  # Filters the project root before it is copied into the store, as the
  # `filter` of builtins.path. The default leaves out node_modules, build
  # outputs of bun-purifier and editor state.
  srcFilter ? null,
}:
let
  projectSrc = if root == "" then src else src + "/${root}";
  # The project directory in the build and in `project`.
  rootPrefix = if root == "" then "" else "${root}/";
  lockName = baseNameOf (toString lockFile);
  # A bun.lock other than the one in `src` is copied over it in the build.
  replacesBunLock = toString bunLock != toString (projectSrc + "/bun.lock");

  inputSelection = purifier.npmInputSelection { inherit dependencies; };
  supplied = {
    providedNames = inputSelection.names;
    providedVersions = inputSelection.versions;
  };

  lock = import ./lock.nix (
    {
      inherit lockFile bunLock;
      root = projectSrc;
    }
    // supplied
  );
  system = stdenvNoCC.hostPlatform.system;

  # The lock in the shape every nix-purifier gives, checked by the shared
  # library, which fails evaluation with its problems.
  checkedLock = purifier.checkLock (
    import ./read-lock.nix { inherit lib purifier; } (
      {
        inherit
          src
          root
          lockFile
          bunLock
          ;
      }
      // supplied
    )
  );

  defaultSrcFilter =
    path: type:
    let
      name = baseNameOf path;
    in
    !(
      (type == "directory" && (name == "node_modules" || name == ".git"))
      || (type == "symlink" && lib.hasPrefix "result" name)
    );

  filteredSrc = builtins.path {
    path = src;
    name = "source";
    filter = if srcFilter != null then srcFilter else defaultSrcFilter;
  };

  minorVersion = v: lib.versions.majorMinor v;
  checkedBun =
    lib.warnIf (lock.bunVersion != null && minorVersion bun.version != minorVersion lock.bunVersion)
      "bun-purifier: ${toString lockFile} was made with bun ${lock.bunVersion}, and this build runs bun ${bun.version}. bun names its cache entries by version-specific rules; if the install fails, relock with this bun."
      bun;

  # Executables in node_modules start with `#!/usr/bin/env node`, and the
  # sandbox has no /usr/bin/env. The build rewrites those lines to this
  # `node`, which is the build's bun under that name, so the scripts run on
  # the bun the project runs on, inside the sandbox and in the output.
  bunAsNode = runCommand "bun-as-node" { } ''
    mkdir -p $out/bin
    ln -s ${checkedBun}/bin/bun $out/bin/node
  '';

  cache = import ./cache.nix { inherit lib purifier; } {
    inherit runCommand;
    fetchers = {
      inherit
        fetchurl
        fetchgit
        runCommand
        unzip
        zstd
        python3
        writeText
        ;
    }
    // fetchers;
    entries = purifier.entriesFor system checkedLock;
    interpreters = [
      checkedBun
      bunAsNode
    ];
  };

  # The offline install, run in the project directory. bun writes into its
  # cache directory, so it gets a writable copy of the tree of links to the
  # unpacked packages.
  inputRepository = purifier.npmInstallRepository {
    inherit dependencies runCommand python3;
  };

  installScript = ''
    cp -r --no-dereference ${cache} $TMPDIR/bun-cache
    chmod -R u+w $TMPDIR/bun-cache
    bun ${../../src}/writable-patches.ts "$PWD" "$TMPDIR/bun-cache"
    ${
      lib.optionalString (dependencies != [ ]) ''
        bun ${../../src}/install-inputs.ts "$PWD" ${inputRepository.catalog} ${inputRepository} \
      ''
    }bun install --frozen-lockfile --offline --no-progress \
      --cache-dir=$TMPDIR/bun-cache --backend=copyfile || {
      echo "bun-purifier: bun could not install offline from the packages of ${lockName}. The lockfile lacks a package that bun.lock needs; run \`bun-purifier lock --force\` and commit the result." >&2
      exit 1
    }
  '';

  # Packages with a name and a version: the ones `bun pm pack` can pack.
  namedPackages = lib.attrValues lock.packagesByName;
  workspacePackages = builtins.filter (p: p.path != "") lock.packages;
  rootPackage = lib.findFirst (p: p.path == "") null lock.packages;

  hasScript = script: p: builtins.elem script (p.scripts or [ ]);

  # Runs `script` in every package that has it: the workspaces through
  # `bun run --filter`, which orders them by their dependencies, then the
  # root package.
  runScript =
    script:
    lib.optionalString (builtins.any (hasScript script) workspacePackages) ''
      bun run --filter '*' --elide-lines=0 ${lib.escapeShellArg script}
    ''
    + lib.optionalString (rootPackage != null && hasScript script rootPackage) ''
      bun run ${lib.escapeShellArg script}
    '';

  packDir = p: lock.storeName p.name;
  packagePath = p: "${rootPrefix}${if p.path == "" then "" else "${p.path}/"}";

  # The project after `bun install` and the `buildScript` of each package,
  # with the tarball of each named package in the output `packs`.
  project = stdenvNoCC.mkDerivation {
    pname = lock.storeName (
      if rootPackage != null && rootPackage ? name then rootPackage.name else "bun-project"
    );
    version = if rootPackage != null && rootPackage ? version then rootPackage.version else "0";
    src = filteredSrc;
    outputs = [
      "out"
      "packs"
    ];
    nativeBuildInputs = [
      checkedBun
      bunAsNode
    ];

    configurePhase = ''
      runHook preConfigure
      # The phases run in one shell, so the build and install phases start
      # in the project too.
      cd ./${rootPrefix}
      export HOME=$TMPDIR/home DO_NOT_TRACK=1
      mkdir -p $HOME
      ${lib.optionalString replacesBunLock ''
        install -m 644 ${bunLock} bun.lock
      ''}
      # Workspace/file dependency executables also need valid interpreters
      # before Bun runs prepare/postinstall hooks during installation.
      patchShebangs --build .
      ${installScript}
      patchShebangs --build $(find . -name node_modules -type d -prune)
      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild
      ${runScript buildScript}
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$packs"
      ${lib.concatMapStrings (p: ''
        mkdir -p $packs/${packDir p}
        bun ${../../src}/pack.ts "$PWD" ${lib.escapeShellArg p.path} "$packs/${packDir p}"
      '') namedPackages}
      # The whole source tree, so file: dependencies outside the project
      # come along. bun installs such a dependency as links to its files
      # in the build directory; each link into the build directory points
      # to the same file in $out instead.
      mkdir -p $out
      build=$NIX_BUILD_TOP/$sourceRoot
      cp -r $build/. $out/
      find $out -type l | while IFS= read -r link; do
        target=$(readlink "$link")
        case "$target" in
          "$build"/*) ln -sfn "$out/''${target#"$build"/}" "$link" ;;
        esac
      done
      runHook postInstall
    '';

    dontFixup = true;
    passthru = { inherit lock cache installScript; };
  };

  # The `bin` field of a package, as a set from executable name to path.
  bins =
    p:
    if !(p ? bin) then
      { }
    else if builtins.isString p.bin then
      { ${lib.last (lib.splitString "/" p.name)} = p.bin; }
    else
      p.bin;

  packages = lib.mapAttrs (
    name: p:
    let
      drv =
        runCommand "${packDir p}-${p.version}"
          {
            meta = lib.optionalAttrs (bins p != { }) { mainProgram = lib.head (lib.attrNames (bins p)); };
            passthru = { inherit project; };
          }
          ''
            mkdir -p $out/lib/node_modules/${builtins.dirOf p.name}
            ln -s ${project}/${packagePath p} $out/lib/node_modules/${p.name}
            mkdir -p $out/bin
            ${lib.concatStrings (
              lib.mapAttrsToList (bin: target: ''
                cat > $out/bin/${lib.escapeShellArg bin} <<EOF
                #!${runtimeShell}
                exec ${checkedBun}/bin/bun ${project}/${packagePath p}${target} "\$@"
                EOF
                chmod +x $out/bin/${lib.escapeShellArg bin}
              '') (bins p)
            )}
          '';
    in
    lib.extendDerivation true {
      projections = projectionFor [ p.name ] // webProjectionFor p.name drv p.version;
      executables = lib.mapAttrs (bin: _: "${drv}/bin/${bin}") (bins p);
    } drv
  ) lock.packagesByName;

  tests =
    runCommand "${project.name}-tests"
      {
        nativeBuildInputs = [
          checkedBun
          bunAsNode
        ];
      }
      ''
        export HOME=$TMPDIR/home DO_NOT_TRACK=1
        mkdir -p $HOME
        cp -r ${project} project
        chmod -R u+w project
        cd project/${rootPrefix}
        ${runScript testScript}
        touch $out
      '';

  # The file name `bun pm pack` gives a package's tarball: the name without
  # a leading "@" and with "/" as "-", then the version.
  packFile =
    p: "${builtins.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "@" p.name)}-${p.version}.tgz";

  # Each release holds a package's tarball, and its `tarball` attribute is
  # the path of that file, known from the lockfile without building. The
  # build fails if bun named the file otherwise.
  release = lib.mapAttrs (
    name: p:
    let
      drv = runCommand "${packDir p}-${p.version}.tgz" { passthru = { inherit project; }; } ''
        mkdir $out
        ln -s ${project.packs}/${packDir p}/${lib.escapeShellArg (packFile p)} $out/
        test -e $out/${lib.escapeShellArg (packFile p)}
      '';
    in
    lib.extendDerivation true {
      tarball = "${drv}/${packFile p}";
      projections = projectionFor [ p.name ];
    } drv
  ) lock.packagesByName;
  capture =
    runCommand "bun-runtime-graph"
      {
        nativeBuildInputs = [
          nodejs
          nix
        ];
        ownPackages = builtins.toJSON (
          map (p: {
            inherit (p) name;
            dir = p.path;
            archive = "${project.packs}/${packDir p}/${packFile p}";
          }) namedPackages
        );
        passAsFile = [ "ownPackages" ];
      }
      ''
        export NPM_PURIFIER_NPM_MODULES=${nodejs}/lib/node_modules/npm/node_modules
        export NPM_PROJECTION_NIX=${nix}/bin/nix
        node ${purifier.npmCaptureTool} ${project}/${rootPrefix} ${project.packs} "$out" "$ownPackagesPath"
      '';
  projectionFor =
    roots:
    purifier.npmProjections {
      graph = "${capture}/graph.json";
      archives = "${capture}/archives";
      producer = project;
      inherit
        roots
        dependencies
        runCommand
        python3
        ;
    };
  packagesForWeb = packages;
  ownPackagesForWeb = lock.packagesByName;
  webProjectionFor =
    name: package: version:
    lib.optionalAttrs (builtins.hasAttr name webAssets) (
      (purifier.resourceProjections {
        producer = project;
        roots."." = "${packagePath ownPackagesForWeb.${name}}${webAssets.${name}}";
        inherit runCommand python3;
      })
      // (purifier.webjarProjections {
        producer = package;
        assets = "${package}/lib/node_modules/${name}/${webAssets.${name}}";
        artifactId = builtins.replaceStrings [ "@" "/" ] [ "" "__" ] name;
        inherit version runCommand python3;
      })
    );
  projections =
    projectionFor null
    // lib.optionalAttrs (webAssets != { }) (
      purifier.jvmProjections {
        repository = null;
        dependencies = lib.mapAttrsToList (name: _: packagesForWeb.${name}) webAssets;
        formats = [
          "maven"
          "ivy"
        ];
        inherit runCommand python3;
      }
    );

in
assert
  builtins.all (name: builtins.hasAttr name ownPackagesForWeb) (builtins.attrNames webAssets)
  || throw "bun-purifier: webAssets must name packages owned by this project";
assert
  builtins.all (
    path:
    builtins.isString path
    && path != ""
    && !lib.hasPrefix "/" path
    && builtins.all (
      part:
      !builtins.elem part [
        ""
        "."
        ".."
        "node_modules"
      ]
    ) (lib.splitString "/" path)
  ) (builtins.attrValues webAssets)
  || throw "bun-purifier: webAssets must select relative asset subdirectories, excluding node_modules";
# checkLock fails evaluation with the problems of the lock, before any
# attribute of the result is read.
builtins.seq checkedLock {
  inherit
    project
    packages
    tests
    release
    projections
    ;
  fetches = checkedLock.entries;
}
