# SPDX-License-Identifier: MIT
#
# The packages of the `bun-purifier` scope. `lib` is the library of this
# flake, whose `purifier` namespace is the shared nix-purifiers library at
# the revision this flake pins.
{ callPackage, lib, ... }:
{
  # The bun-purifier command: `lock`, `update`, `prefetch` and `publish`.
  bun-purifier = callPackage ./bun-purifier { inherit (lib) purifier; };

  # The sandboxed builds of a bun project (pkgs/build-bun-project). A
  # package for callPackage in this scope, so `buildBunProject.override`
  # replaces what it takes, and an overlay on the scope with
  # `overrideScope` replaces what every package in the scope shares.
  buildBunProject = callPackage ./build-bun-project {
    inherit (lib) purifier;
  };
}
