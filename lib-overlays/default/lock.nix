# SPDX-License-Identifier: MIT
#
# The locked state of a bun project: bun.lock, the package manifests, and
# the facts `bun-purifier lock` records in bun-purifier.lock.json because
# bun.lock cannot hold them.
#
# bun.lock names every downloaded package with its URL and integrity
# hash, and bun's own platform filters. From it, this file derives the
# download entries of the shared nix-purifiers library and the cache path
# bun gives each package. The lockfile adds what bun.lock leaves out:
#
#   bunLockHash      SHA-256 of bun.lock, so the facts below go stale when
#                    bun.lock changes
#   bunVersion       the bun the lock ran, whose rules name cache entries
#   defaultRegistry  the default registry, when it is not the npm registry,
#                    since it can come from the environment or from
#                    configuration in the home directory
#   cachePaths       the cache path of each package whose path bun derives
#                    with an internal hash (prerelease versions, tarball
#                    URLs), by bun.lock key
#   gitHashes        the NAR hash of each git checkout, by bun.lock key
#   notInstalled     the bun.lock keys of packages bun installs on no system
#                    the nix-purifiers build for
#
# When the lock finds none of these, it writes no lockfile, and everything
# comes from bun.lock.
#
# Needs no nixpkgs: the interactive mode of the command evaluates this
# with nothing but the Nix installation it runs.
{
  # The lockfile, which need not exist.
  lockFile,
  # The project root, which holds the package manifests.
  root,
  # The project's bun.lock, which may lie outside `root`.
  bunLock ? root + "/bun.lock",
  providedNames ? [ ],
  providedVersions ? [ ],
}:
let
  supportedVersion = import ./lock-version.nix;
  name = toString lockFile;
  baseName = baseNameOf name;

  exists = builtins.pathExists lockFile;
  text = if exists then builtins.readFile lockFile else "";

  # A merge that conflicted in the lockfile leaves conflict markers, which
  # are not JSON. They are looked for before the text is parsed, so the
  # error names the conflict rather than a JSON syntax error.
  conflicted = builtins.length (builtins.split "\n<<<<<<< " ("\n" + text)) > 1;

  noFacts = {
    version = supportedVersion;
    cachePaths = { };
    gitHashes = { };
    notInstalled = [ ];
  };

  lock =
    if !exists || conflicted then
      noFacts
    else
      # A parse error cannot be caught, so the context it carries names the
      # command that rewrites the file.
      builtins.addErrorContext
        "bun-purifier: ${name} is not valid JSON. Run `bun-purifier lock --force` to rewrite it."
        (builtins.fromJSON text);

  # The digest that `bun-purifier lock` records as `contentHash`: SHA-256
  # of the rest of the lockfile as JSON with sorted keys and no whitespace,
  # the way builtins.toJSON writes it. src/lock.ts computes it the same
  # way. A lockfile edited by hand no longer matches it.
  contentHash = builtins.hashString "sha256" (builtins.toJSON (removeAttrs lock [ "contentHash" ]));

  bunLockHash = builtins.hashFile "sha256" bunLock;
  bunLockData = import ./bun-lock.nix bunLock;

  storeName = import ./store-name.nix;

  # A bun.lock package key, `<name>@<resolution>`, where a scoped name
  # starts with "@" itself.
  splitKey =
    key:
    let
      m = builtins.match "(@[^@]+|[^@]+)@(.*)" key;
    in
    {
      name = builtins.elemAt m 0;
      resolution = builtins.elemAt m 1;
    };

  hasPrefix = prefix: s: builtins.substring 0 (builtins.stringLength prefix) s == prefix;

  # Dependencies on a local directory or tarball are part of the source.
  isLocal =
    resolution:
    hasPrefix "file:" resolution
    || hasPrefix "./" resolution
    || hasPrefix "../" resolution
    || hasPrefix "/" resolution;

  # The host of a registry URL as bun writes it in cache names: none for
  # the npm registry.
  cacheHost =
    url:
    let
      host = builtins.head (builtins.match "[a-z+]+://([^/]+).*" url);
    in
    if host == "registry.npmjs.org" then "" else host;

  defaultRegistry = lock.defaultRegistry or "https://registry.npmjs.org/";

  # The URL Nix fetches a git dependency from. The sandbox has no SSH keys,
  # so an SSH URL becomes the HTTPS URL of the same repository, which is
  # what bun falls back to as well. src/lock.ts has the same rule.
  gitFetchUrl =
    resolution:
    let
      url = builtins.elemAt (builtins.match "(git\\+)?([^#]*).*" resolution) 1;
      ssh = builtins.match "ssh://([^@/]+@)?([^/:]+)(:[0-9]+)?/(.+)" url;
      scp = builtins.match "([^@/]+@)?([^/:]+):([^/].*)" url;
    in
    if ssh != null then
      "https://${builtins.elemAt ssh 1}/${builtins.elemAt ssh 3}"
    else if scp != null && builtins.match "[a-z]+://.*" url == null then
      "https://${builtins.elemAt scp 1}/${builtins.elemAt scp 2}"
    else
      url;

  # The download entry of a bun.lock package, in the shapes of the shared
  # library, with the cache path bun gives it, its platform filters and
  # what is missing to fetch it. Null for a package that is part of the
  # source.
  entryOf =
    key: value:
    let
      inherit (splitKey (builtins.head value)) name resolution;
      recorded = lock.cachePaths.${key} or null;
      filters = meta: {
        os = meta.os or null;
        cpu = meta.cpu or null;
        libc = meta.libc or null;
      };
      archive = url: {
        inherit url;
        mirrors = [ ];
        stripTop = true;
      };
      github = builtins.match "github:([^/]+)/([^#]+)#(.+)" resolution;
    in
    if
      builtins.elem name providedNames
      || builtins.elem {
        inherit name;
        version = resolution;
      } providedVersions
    then
      null
    else if builtins.match "(workspace|root):.*" resolution != null || isLocal resolution then
      null
    else if hasPrefix "link:" resolution then
      {
        inherit key;
        problem = "bun-purifier: ${key} in bun.lock is a link: dependency, which names a package registered with `bun link` on one machine. Depend on the package with file: and its path instead.";
      }
    else if builtins.match "git(\\+|:).*" resolution != null then
      let
        rev = builtins.elemAt value 2;
      in
      {
        inherit key;
        entry = {
          path = if recorded != null then recorded else "@G@${rev}";
          git = {
            url = gitFetchUrl resolution;
            inherit rev;
            submodules = false;
            leaveDotGit = false;
            commitObject = null;
          };
          hash = lock.gitHashes.${key} or null;
        }
        // filters (builtins.elemAt value 1);
        problem =
          if lock.gitHashes ? ${key} then
            null
          else
            "bun-purifier: ${baseName} has no hash for the git dependency ${key}. Run `bun-purifier lock`.";
      }
    else if github != null then
      {
        inherit key;
        entry = {
          path = if recorded != null then recorded else "@GH@${builtins.elemAt value 2}@@@1";
          archive = archive "https://api.github.com/repos/${builtins.elemAt github 0}/${builtins.elemAt github 1}/tarball/${builtins.elemAt github 2}";
          hash = builtins.elemAt value 3;
        }
        // filters (builtins.elemAt value 1);
      }
    else if builtins.match "https?://.*" resolution != null then
      {
        inherit key;
        entry = {
          path = recorded;
          archive = archive resolution;
          hash = builtins.elemAt value 2;
        }
        // filters (builtins.elemAt value 1);
        problem =
          if recorded != null then
            null
          else
            "bun-purifier: ${baseName} has no cache path for the tarball dependency ${key}. Run `bun-purifier lock`.";
      }
    else
      let
        tarball = builtins.elemAt value 1;
        unscoped = baseNameOf name;
        registryUrl = if tarball != "" then tarball else defaultRegistry;
        host = cacheHost registryUrl;
      in
      {
        inherit key;
        entry = {
          path =
            if recorded != null then
              recorded
            else
              "${name}@${resolution}${if host == "" then "" else "@@${host}"}@@@1";
          archive = archive (
            if tarball != "" then tarball else "${defaultRegistry}${name}/-/${unscoped}-${resolution}.tgz"
          );
          hash = builtins.elemAt value 3;
        }
        // filters (builtins.elemAt value 2);
      };

  derived = builtins.filter (e: e != null && !(builtins.elem e.key lock.notInstalled)) (
    builtins.attrValues (builtins.mapAttrs entryOf bunLockData.packages)
  );

  # bun.lock keys a package by where it sits in the dependency tree, so two
  # keys can name the same version, which bun keeps in one cache entry.
  entries =
    let
      byPath = builtins.listToAttrs (
        map (e: {
          name = e.entry.path;
          value = e.entry;
        }) (builtins.filter (e: e ? entry && e.entry.path != null) derived)
      );
    in
    map (path: byPath.${path}) (builtins.attrNames byPath);

  entryProblems = builtins.filter (p: p != null) (map (e: e.problem or null) derived);

  # The packages of the project: the workspaces of bun.lock, with the
  # fields of their manifests.
  manifestPath = path: if path == "" then "package.json" else "${path}/package.json";
  packages = map (
    path:
    let
      manifest = builtins.fromJSON (builtins.readFile (root + "/${manifestPath path}"));
    in
    {
      inherit path;
      scripts = builtins.attrNames (manifest.scripts or { });
    }
    // (if manifest ? name then { inherit (manifest) name; } else { })
    // (if manifest ? version then { inherit (manifest) version; } else { })
    // (if manifest ? bin then { inherit (manifest) bin; } else { })
  ) (builtins.attrNames bunLockData.workspaces);

  # What makes the lockfile unusable, each as a message that names the
  # command to run.
  integrityProblems =
    if conflicted then
      [
        "bun-purifier: ${name} has merge conflict markers. Resolve the conflict in bun.lock, then run `bun-purifier lock --force` to rewrite ${baseName}."
      ]
    else if lock.version or null != supportedVersion then
      [
        "bun-purifier: ${name} has lock format version ${
          toString (lock.version or "none")
        }; this library reads version ${toString supportedVersion}. Run `bun-purifier lock --force` with the bun-purifier that provides this library."
      ]
    else if exists && contentHash != lock.contentHash or null then
      [
        "bun-purifier: the content of ${name} does not match the digest `bun-purifier lock` recorded, so the file was edited after the lock. Run `bun-purifier lock --force` to rewrite it."
      ]
    else
      [ ];

  # Whether bun.lock changed since the lock was made.
  stale = integrityProblems == [ ] && exists && bunLockHash != lock.bunLockHash;
in
{
  inherit
    storeName
    integrityProblems
    stale
    entries
    packages
    ;
  bunVersion = lock.bunVersion or null;

  # Every problem of the lock for a build.
  problems =
    integrityProblems
    ++ (
      if stale then
        [
          "bun-purifier: bun.lock under ${toString root} changed since ${name} was made. Run `bun-purifier lock`."
        ]
      else
        [ ]
    )
    ++ (if integrityProblems == [ ] && !stale then entryProblems else [ ]);

  # The fetch name of an entry: the last component of its cache path.
  artifactName = entry: storeName (baseNameOf entry.path);

  packagesByName = builtins.listToAttrs (
    map (p: {
      inherit (p) name;
      value = p;
    }) (builtins.filter (p: p ? name && p ? version) packages)
  );
}
