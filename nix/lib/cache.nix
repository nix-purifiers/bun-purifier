# SPDX-License-Identifier: MIT
#
# The bun install cache of a list of download entries, those of one
# system (`entriesFor` of the shared library, on the lock that readLock
# gives). The shared library (`purifier`) turns each entry into a store
# path of its own: an archive entry into the unpacked package, a git entry
# into the checkout. The cache links each one at its path, the directory
# name bun gives the package (`kleur@4.1.5@@@1`). A store path per package
# lets projects that lock the same package share it.
#
# bun writes into its cache directory, so a build copies this tree of
# links to a writable directory first. build-bun-project.nix does that,
# and so does `bun-purifier prefetch`.
{
  lib,
  # The `purifier` library namespace: `fetchEntry`.
  purifier,
}:
{
  runCommand,
  # The download entries the cache holds.
  entries,
  # The fetchers and packages `fetchEntry` takes by name, passed to it
  # unchanged.
  fetchers,
  # Sandbox builds patch dependency executables before install hooks run.
  # A development prefetch leaves these empty and keeps the linked cache.
  interpreters ? [ ],
}:
let
  storeName = import ./store-name.nix;

  fetchEntry = purifier.fetchEntry fetchers;

  # bun keeps a git dependency as the checkout of its commit, with the
  # commit in a file `.bun-tag`, and an offline install looks for that
  # file.
  withBunTag =
    entry:
    runCommand (storeName (baseNameOf entry.path))
      {
        src = fetchEntry entry;
        inherit (entry.git) rev;
        preferLocalBuild = true;
      }
      ''
        cp -r "$src" $out
        chmod -R u+w $out
        printf %s "$rev" > $out/.bun-tag
      '';

  unpatchedStorePath = entry: if entry ? git then withBunTag entry else fetchEntry entry;

  # Keep one patched store path per dependency, shared by every project
  # using this interpreter. Copying the entire cache would duplicate all
  # dependencies in the store for each project.
  storePath =
    entry:
    if interpreters == [ ] then
      unpatchedStorePath entry
    else
      runCommand "${storeName (baseNameOf entry.path)}-bun"
        {
          src = unpatchedStorePath entry;
          nativeBuildInputs = interpreters;
          preferLocalBuild = true;
        }
        ''
          cp -r --no-dereference "$src" "$out"
          chmod -R u+w "$out"
          source ${./patch-shebangs.sh}
          patchBunShebangs "$out"
        '';
in
# The manifest goes to the builder as a file, since a large project locks
# thousands of entries and the list would not fit in an environment
# variable.
runCommand "bun-install-cache"
  {
    manifest = lib.concatMapStrings (e: "${e.path}\t${storePath e}\n") entries;
    passAsFile = [ "manifest" ];
    preferLocalBuild = true;
    allowSubstitutes = false;
  }
  ''
    mkdir -p $out
    while IFS=$'\t' read -r rel target; do
      mkdir -p "$out/$(dirname "$rel")"
      ln -s "$target" "$out/$rel"
    done < "$manifestPath"
  ''
