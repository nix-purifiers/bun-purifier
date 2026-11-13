# SPDX-License-Identifier: MIT
#
# Local commands adopt the caller's Bun from PATH. Capture, observation
# and offline installation keep that executable; sandboxed publication
# selects its SDK separately.
#
# BUN_PURIFIER_LIB names nix/lib, which `install` and `publish` build
# from, and BUN_PURIFIER_NIXPKGS names the nixpkgs of this package set,
# which those builds import. The builds run the `nix` on the user's PATH.
# `lock` hashes git dependencies with nix-prefetch-git, which comes with
# the package.
{
  lib,
  purifier,
  stdenvNoCC,
  makeWrapper,
  runtimeShell,
  bun,
  python3,
  nix-prefetch-git,
  path,
}:
stdenvNoCC.mkDerivation {
  pname = "bun-purifier";
  version = import ../version.nix;

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../src
      ../../nix/lib
      # nix/lib/interactive.nix takes the revision of the shared library
      # from it.
      ../../flake.lock
    ];
  };

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/bun-purifier
    cp -r src nix flake.lock $out/share/bun-purifier/
    makeWrapper ${runtimeShell} $out/bin/bun-purifier \
      --add-flags $out/share/bun-purifier/src/host-bun.sh \
      --add-flags $out/bin/bun \
      --add-flags $out/share/bun-purifier/src/host-bootstrap.mjs \
      --add-flags $out/share/bun-purifier/src/main.ts \
      --set BUN_PURIFIER_LIB $out/share/bun-purifier/nix/lib \
      --set BUN_PURIFIER_NIXPKGS ${path} \
      --set BUN_PURIFIER_PYTHON ${lib.getExe python3} \
      --set BUN_PURIFIER_PROJECT_INPUTS ${purifier.projectInputsTool} \
      --prefix PATH : ${
        lib.makeBinPath [
          nix-prefetch-git
        ]
      }
    makeWrapper ${runtimeShell} $out/bin/bun \
      --add-flags $out/share/bun-purifier/src/host-bun.sh \
      --add-flags $out/bin/bun \
      --add-flags $out/share/bun-purifier/src/host-bootstrap.mjs \
      --add-flags $out/share/bun-purifier/src/main.ts \
      --set BUN_PURIFIER_TOOL_WRAPPER 1 \
      --set BUN_PURIFIER_LIB $out/share/bun-purifier/nix/lib \
      --set BUN_PURIFIER_NIXPKGS ${path} \
      --set BUN_PURIFIER_PYTHON ${lib.getExe python3} \
      --set BUN_PURIFIER_PROJECT_INPUTS ${purifier.projectInputsTool} \
      --prefix PATH : ${
        lib.makeBinPath [
          nix-prefetch-git
        ]
      }
    runHook postInstall
  '';

  # Retain the package set's SDK as a pure-build convenience, not a
  # dependency or admission requirement of the local launcher.
  passthru = { inherit bun; };

  meta = {
    description = "Locks bun projects for sandboxed Nix builds, and installs and publishes from the lock";
    license = lib.licenses.mit;
    mainProgram = "bun-purifier";
  };
}
