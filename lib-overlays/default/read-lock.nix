# SPDX-License-Identifier: MIT
#
# readLock: bun.lock and bun-purifier.lock.json, read into the lock shape
# that every nix-purifier gives (CONTRACT.md of the shared library):
#
#   purifier   "bun-purifier"
#   entries    the download entries of the shared library. An entry that
#              npm's `os`, `cpu` and `libc` filters admit on only some of
#              the systems the nix-purifiers build for carries `systems`,
#              the systems that install it.
#   outputs    each package of the project with a name and a version, by
#              name: its directory in the project, its version, and its
#              `bin` field when it has one
#   problems   why the lockfiles cannot be used, each naming the command
#              that fixes it
#
# The library overlay publishes it as `lib.bun-purifier.readLock`.
{
  lib,
  # The `purifier` library namespace of the shared nix-purifiers library.
  purifier,
}:
{
  # The source tree, as buildBunProject takes it.
  src,
  # The project inside `src`; "" when `src` is the project.
  root ? "",
  # The lockfile, by default bun-purifier.lock.json at the project root.
  lockFile ? (if root == "" then src else src + "/${root}") + "/bun-purifier.lock.json",
  # The project's bun.lock, by default the one at the project root. An
  # external build passes the copy it keeps outside the repository.
  bunLock ? (if root == "" then src else src + "/${root}") + "/bun.lock",
  providedNames ? [ ],
  providedVersions ? [ ],
}:
let
  projectSrc = if root == "" then src else src + "/${root}";

  lock = import ./lock.nix {
    inherit
      lockFile
      bunLock
      providedNames
      providedVersions
      ;
    root = projectSrc;
  };

  # The systems the nix-purifiers build for.
  systems = [
    "x86_64-linux"
    "aarch64-linux"
    "aarch64-darwin"
  ];

  withSystems =
    entry:
    let
      filters = {
        os = entry.os or null;
        cpu = entry.cpu or null;
        libc = entry.libc or null;
      };
      admitted = builtins.filter (purifier.admits filters) systems;
      plain = removeAttrs entry [
        "os"
        "cpu"
        "libc"
      ];
    in
    if admitted == systems then plain else plain // { systems = admitted; };
in
{
  purifier = "bun-purifier";

  entries = builtins.filter (e: (e.systems or systems) != [ ]) (map withSystems lock.entries);

  outputs = builtins.mapAttrs (
    _: p:
    {
      inherit (p) path version;
    }
    // lib.optionalAttrs (p ? bin) { inherit (p) bin; }
  ) lock.packagesByName;

  inherit (lock) problems;
}
