# SPDX-License-Identifier: MIT
#
# What the command builds outside a flake: `cache` for
# `bun-purifier prefetch` and `release` for `bun-purifier publish`. The
# command passes the nixpkgs its flake pins and absolute paths in the
# project.
#
# The shared nix-purifiers library comes from its flake's `lib` output, at
# the revision the flake.lock of bun-purifier pins. The command package
# keeps that flake.lock next to this directory.
{
  nixpkgs,
  system ? builtins.currentSystem,
  # The project root, which holds bun.lock and the package manifests.
  src,
  # The project's lockfile, which need not exist.
  lockFile,
  # A package name, for `release`.
  package ? null,
  projectInputs ? "[]",
}:
let
  pkgs = import nixpkgs { inherit system; };
  inherit (pkgs) lib;

  flakeLock = builtins.fromJSON (builtins.readFile ../../flake.lock);
  locked = flakeLock.nodes.${flakeLock.nodes.root.inputs.purifier}.locked;
  purifierFlake = builtins.getFlake "github:${locked.owner}/${locked.repo}/${locked.rev}?narHash=${locked.narHash}";
  inherit (purifierFlake.lib) purifier;

  lock = import ../../lib-overlays/default/read-lock.nix { inherit lib purifier; } {
    src = /. + src;
    lockFile = /. + lockFile;
  };
in
{
  npmInputs =
    let
      repository = purifier.npmInstallRepository {
        dependencies = purifier.lockedProjectInputs {
          inputs = builtins.fromJSON projectInputs;
          inherit system;
        };
        inherit (pkgs) runCommand python3;
      };
    in
    [
      repository
      repository.metadata
    ];

  cache = import ../build-bun-project/cache.nix { inherit lib purifier; } {
    inherit (pkgs) runCommand;
    fetchers = { inherit pkgs; };
    entries = purifier.entriesFor system lock;
  };

  npmPublication =
    let
      buildBunProject = pkgs.callPackage ../build-bun-project { inherit purifier; };
      build = buildBunProject {
        src = /. + src;
        lockFile = /. + lockFile;
      };
      repository = build.packages.${package}.projections.npm;
    in
    pkgs.runCommand "bun-npm-publication" { } ''
      mkdir -p "$out"
      cp -rs ${repository}/. "$out/"
      ln -s ${repository.catalog} "$out/catalog.json"
    '';

  release =
    let
      buildBunProject = pkgs.callPackage ../build-bun-project { inherit purifier; };
      build = buildBunProject {
        src = /. + src;
        lockFile = /. + lockFile;
      };
    in
    build.release.${package};
}
