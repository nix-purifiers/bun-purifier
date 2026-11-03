# bun-purifier

bun-purifier keeps Bun's development workflow on locked,
Nix-resolved dependencies. Use the normal build and test commands in your
working tree; building the project itself in the Nix sandbox is an
optional next step.

bun still resolves the project and writes `bun.lock`, and Nix reads
`bun.lock` itself: every package with its URL and integrity hash. Nix
then fetches every package, lays out bun's install cache and runs
`bun install --offline` in the sandbox. For the few facts `bun.lock`
cannot hold, bun-purifier writes `bun-purifier.lock.json`, and a project
that needs none of them has no such file. Nothing generated in Nix needs
to be committed.

## Quickstart

From the project root:

```zsh
nix shell 'github:nix-purifiers/bun-purifier'
bun-purifier lock
bun-purifier prefetch
bun run build
bun test
```

Commit the lockfiles that the lock command writes, including the build
tool's own lockfile when it has one. Keep using the project's usual build,
test and editor commands with this setup. Nix provides the locked
dependencies; the development commands above run outside the Nix sandbox.
No project Nix files are needed for this workflow.

Sandboxed builds of the whole project are an optional
[next step](#building-the-project-with-nix).

For persistent use, add these packages through your usual Nix configuration.


## Development loop

`nix shell` supplies a `bun` wrapper. `bun install`, `bun run build`
and `bun test` use the Nix-resolved dependencies. `bun add`, `bun remove`
and `bun update` update the native lock and record any additional facts
Nix needs. After editing `package.json` by hand, run `bun-purifier lock`.
Without a lockfile, the wrapper warns and runs ordinary, impure Bun.

To move every dependency, or the named ones, to the newest versions
their ranges allow, run

```zsh
nix shell 'github:nix-purifiers/bun-purifier'
bun-purifier update
```

Pass package names to `bun-purifier update` to update only those packages.

`update` runs `bun update`, which rewrites `bun.lock`, and then locks
against the new `bun.lock`. `lock` keeps the versions `bun.lock` has.

`bun-purifier prefetch` refuses a lockfile older than `bun.lock` and names
`bun-purifier lock`, and so does the Nix build.

## Dependencies from other purified projects

Pass a producer's Nix output when locking:

```zsh
nix shell 'github:nix-purifiers/bun-purifier'
bun-purifier lock --input 'github:example/library#library'
bun install
bun test
```

The producer can use Bun, npm or pnpm. Nix supplies its artifact identities
and overrides ordinary version requests automatically. `projectInputs`
pins the Nix sources; supplied artifacts stay out of `bun.lock` and download
entries. Bun receives a temporary native lock reconstructed from those inputs.

The builder accepts these outputs through `dependencies = [ library ];`
and exports `projections.npm`. Individual `packages.<name>` and
`release.<name>` also export `projections.npm` with that package's runtime
dependencies. A build uses its recorded `projectInputs` by default.

For a composed project, `bun-purifier publish` publishes the namespaced
archives and their exact dependency requirements, using the `nix` tag by
default. Ordinary package managers can consume the result. An already
published dependency is reused only when its integrity matches the Nix
input.

## Building the project with Nix

Once the native development workflow is working, you can also build and
test the whole project in the Nix sandbox. For this step, keep a flake or
another Nix build definition in the project's repository, or maintain an
external packaging repository that points at its sources and lockfiles.
The builder consumes the same lockfiles as the development workflow.

The flake's `overlays.default` adds one attribute to a package set: the
scope `bun-purifier`, which holds the builder `buildBunProject` and the
`bun-purifier` command.

To package the project in a flake, call the builder in the flake. The
flake can live in the project's repository or in another one:

```nix
{
  inputs.bun-purifier.url =
    "github:nix-purifiers/bun-purifier";
  inputs.nixpkgs.follows = "bun-purifier/nixpkgs";

  outputs =
    { nixpkgs, bun-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ bun-purifier.overlays.default ];
      };
      project = pkgs.bun-purifier.buildBunProject {
        src = ./.;
      };
    in
    {
      packages.${system}.default =
        project.packages.my-app;
    };
}
```

The builder takes what it needs from the scope and the package set, such
as `bun`, `stdenvNoCC` and `fetchurl`. `bun-purifier.buildBunProject.override`
replaces what the builder takes, and `bun-purifier.overrideScope`
replaces what everything in the scope shares. The builder
`buildBunProject { src, lockFile ? ..., bunLock ? ..., fetchers ? { }, ... }`
returns

- `packages.<name>`: package `<name>`, built: its directory in the built
  project at `lib/node_modules/<name>`, and the executables of its `bin`
  field in `bin/`, run by bun. `packages.<name>.executables.<bin>` is the
  path of each executable.
- `tests`: the `test` script of every package that has one, run in the
  sandbox on the built project.
- `release.<name>`: the tarball of package `<name>`, as `bun pm pack`
  makes it and `bun-purifier publish` uploads it.
  `release.<name>.tarball` is the path of the file.
- `fetches`: the download entries of the shared
  [purifier](https://github.com/nix-purifiers/purifier) library that the
  lock lists, for every system the nix-purifiers build for, as `readLock`
  gives them.

Nix knows every one of these attributes, by name, at evaluation time.
`bun.lock` lists the project's packages with their directories, and Nix
reads the name, version and `bin` field of each from its `package.json`.

`nix/lib/build-bun-project.nix` documents the other arguments:

- `root`: the project inside `src`, for `file:` dependencies outside the
  project (see Supported language repositories).
- `lockFile` and `bunLock`: the two lockfiles, by default the ones next
  to `package.json` in `src`. An external build passes copies kept
  outside the repository, and a `bunLock` given here replaces the
  `bun.lock` in `src` for the build. See External builds.
- `fetchers`: passed unchanged to `fetchEntry` of the shared library.
  `fetchers.fetchurl` serves a registry mirror or credentials, and
  `fetchers.fetchgit` a private git repository.
- `buildScript` and `testScript`: the package scripts that build and
  test, `build` and `test` by default.
- `srcFilter`: filters the source before it is copied into the store.

The build runs the package set's bun. Executables in `node_modules`
start with `#!/usr/bin/env node`, and the sandbox has no `/usr/bin/env`,
so the build rewrites those lines to a `node` that is that bun.

### How the lock is made

`bun.lock` names every downloaded package with its URL, its integrity
hash and npm's platform filters. bun writes it as JSON with trailing
commas, and Nix reads it after dropping those commas. Each package
becomes a download entry of the shared library: an archive entry for a
tarball, a git entry for a git checkout. The library fetches and unpacks
the entries, and decides from the platform filters which ones a system
installs. Nix also derives the name of each package's entry in bun's
install cache, because an offline install finds a package only under
that name.

`bun-purifier lock` first makes sure `bun.lock` matches the package
manifests. A `bun.lock` that matches stays as it is. A missing or binary
`bun.lock`, or one that lacks a dependency of a manifest, gets
`bun install --lockfile-only`, which keeps every resolution `bun.lock`
records and resolves only the rest.

`bun-purifier lock` then records what Nix cannot derive. It copies the project
to a temporary directory and installs it into an empty cache once for
each system the nix-purifiers build for, x86_64-linux, aarch64-linux and
aarch64-darwin, and compares what bun did with what Nix derives. The
lockfile records:

| Field | Why `bun.lock` cannot supply it |
|---|---|
| `cachePaths` | bun names prerelease versions and tarball URLs with hashes of its own. |
| `gitHashes` | `bun.lock` records the commit of a git dependency, not a hash of the checkout. |
| `notInstalled` | Which packages bun installs on none of the systems, such as a dependency of a WebAssembly fallback, follows from resolution. |
| `defaultRegistry` | The default registry can come from the environment or from configuration in the home directory. |
| `bunLockHash`, `bunVersion` | They tie the facts to one `bun.lock` and to the bun whose rules name cache entries. |

The lockfile also holds a format `version` and a digest of its own
content. When none of the facts applies, the lock writes no lockfile.
`bun-purifier lock` relocks only when `bun.lock` changed, or with
`--force`, and a relock of an unchanged project writes the same file byte
for byte, or again none.

`lib.bun-purifier.readLock` takes the same `src`, `root`, `lockFile` and
`bunLock` as the builder. It reads both lockfiles into the shape every
nix-purifier gives, `{ purifier, entries, outputs, problems }`. An entry that only some of
the systems install carries `systems`. The builder checks this lock with
`checkLock` of the shared library and fetches the entries of its system.

### External builds

A project that does not use bun-purifier can still be built from a
flake. The flake keeps both lockfiles outside the repository and passes
them to the builder:

```nix
bun-purifier.buildBunProject {
  # the source of the project, which has no
  # bun-purifier.lock.json
  src = project;
  lockFile = ./locks/bun-purifier.lock.json;
  bunLock = ./locks/bun.lock;
}
```

The commands take the same two paths. `--lockfile <path>` or the
environment variable `BUN_PURIFIER_LOCKFILE` names `bun-purifier.lock.json`,
and `--tool-lockfile <path>` or `BUN_PURIFIER_TOOL_LOCKFILE` names
`bun.lock`. The dev shell of the flake can set both variables, so the
commands need no flags there. An option takes precedence over its
variable.

With a `bun.lock` path, `lock` and `update` write `bun.lock` at that
path and leave the `bun.lock` in the working tree as it is. When the file
at that path does not exist yet, they start from the `bun.lock` in the
working tree.

### One-off builds without a project Nix file

For an ad hoc build, the builder can also be evaluated directly from the
project root. Replace the example package name with one from your project:

```zsh
nix build --impure --expr 'let
  purifier = builtins.getFlake "github:nix-purifiers/bun-purifier";
  pkgs = import purifier.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ purifier.overlays.default ];
  };
in
(pkgs.bun-purifier.buildBunProject { src = ./.; })
.packages.my-app'
```

This uses the purifier's pinned nixpkgs, matching the lock command above.
To build with ambient `<nixpkgs>` from your Nix search path instead,
replace `import purifier.inputs.nixpkgs` with `import <nixpkgs>`.
Both forms need no Nix files in your project. The build tool and language
versions must match the lockfile; with ambient nixpkgs, lock with the
purifier from that package set or pass a compatible toolchain to the builder.

## Working offline

```zsh
nix shell 'github:nix-purifiers/bun-purifier'
bun-purifier prefetch
```

`prefetch` builds, in the Nix store, every package `bun.lock` lists for
the current system, keeps them alive with a garbage-collector root, and
runs
`bun install --frozen-lockfile --offline` from them. Further arguments go
to `bun install`. After it, `bun install`, `bun run`, `bun test` and the
editor work with the network cut off. `bun add` of a package not in the
lock needs the network, as it does without bun-purifier.

The garbage-collector root lies at `node_modules/.cache/bun-purifier`
rather than beside the purifier lockfile, because a project whose
`bun.lock` records everything has no purifier lockfile. Removing
`node_modules` removes the root with the packages it keeps.

## Editor

`prefetch` leaves `node_modules` with ordinary files, so an editor's
TypeScript server, and `tsc`, read the installed types as after a plain
`bun install`. bun projects bring TypeScript and their `@types` packages
as dependencies, so `bun.lock` holds what the editor reads, and it is
there after `prefetch`.

## Troubleshooting

Every check names the command that fixes it, in the command and in the
Nix build:

| Situation | Message ends with |
|---|---|
| `bun.lock` or a `package.json` changed after the lock | Run `bun-purifier lock`. |
| `bun-purifier.lock.json` edited by hand | Run `bun-purifier lock --force` to rewrite it. |
| Merge conflict in `bun-purifier.lock.json` | Resolve the conflict in bun.lock, then run `bun-purifier lock --force` |
| `bun-purifier.lock.json` is not JSON | Run `bun-purifier lock --force` to rewrite it. |
| The lockfile lacks a package bun needs | run `bun-purifier lock --force` and commit the result. |
| A `link:` dependency | Depend on the package with file: and its path instead. |

`bun-purifier publish` builds the release tarball of the package in the
working directory, or of the one named with `--package`, and runs
`bun publish` with it in the package's directory. Registry configuration
and credentials work as they do for `bun publish`.

## Supported language repositories

Every kind of dependency `bun.lock` records builds, except one:

- **Registry packages.** The default registry comes from the sources bun
  reads, first match winning: the `BUN_CONFIG_REGISTRY` and
  `NPM_CONFIG_REGISTRY` variables, the project's `bunfig.toml` and
  `.npmrc`, then the user's `.bunfig.toml` and `.npmrc`. A package from a
  scoped registry carries its own URL in `bun.lock`. A registry that needs
  credentials needs a `fetchers.fetchurl` with them in the Nix build.
- **`github:` dependencies and `git+https:` URLs on GitHub.** bun
  downloads these as tarballs from the GitHub API, and so does Nix.
- **Other git dependencies** (`git+https:`, `git+ssh:`, `git:`). bun
  clones them, and Nix fetches the same commit with `fetchgit`. The lock
  hashes the checkout with `nix-prefetch-git`. bun clones without
  submodules, so the lock does too. The sandbox has no SSH keys, so Nix
  fetches an SSH URL over HTTPS from the same host, as bun does when SSH
  fails. A private repository needs a `fetchers.fetchgit` with
  credentials.
- **Tarball URLs.**
- **Local directories and tarballs** (`file:` and plain paths). These
  are part of the source, and bun installs them from there. When one lies
  outside the project, pass the directory above both as `src` and the
  project's place in it as `root`.
- **Per-platform optional packages**, such as esbuild's binaries. Each
  system the nix-purifiers build for fetches the packages whose platform
  filters admit it.
- **`link:` dependencies are refused, because they cannot work.**
  `link:<name>` names a package that `bun link` registered in bun's global
  directory on one machine, and `bun.lock` records only the name. Neither
  Nix nor another machine can tell what the name pointed to, so
  `bun-purifier lock` stops with a message. A `file:` dependency on the
  same directory works.

bun runs no lifecycle scripts of dependencies, so a dependency that
downloads a binary in `postinstall` lacks it in the sandbox as it does
outside.

The lockfile records the version of bun that made it, because the names
of cache entries follow the rules of that version. A build with a bun of
another minor version prints a warning. The `bun-purifier` command runs
the bun of its own package set, so `lock`, `prefetch` and `publish` agree
with each other.

## Examples

For day-to-day work on these projects, use the native-tool setup and
commands in [Quickstart](#quickstart) and [Development loop](#development-loop).
The Nix expressions below show optional sandboxed packaging of those
projects.

### elysia

[elysia](https://github.com/elysiajs/elysia) is a web framework for bun.
In a checkout of it, lock the project:

```zsh
nix shell 'github:nix-purifiers/bun-purifier'
bun-purifier lock
```

elysia has optional dependencies that only a WebAssembly fallback
installs, so the lock writes `bun-purifier.lock.json`. Commit it next to
`bun.lock`.

Then build it from the checkout. This runs elysia's own `build` script:

```zsh
nix build --impure --expr 'let
  purifier = builtins.getFlake "github:nix-purifiers/bun-purifier";
  pkgs = import purifier.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ purifier.overlays.default ];
  };
in
(pkgs.bun-purifier.buildBunProject { src = ./.; })
.packages.elysia'
```

The builder returns more than the package. Name `release.elysia` in
place of `packages.elysia` to build the tarball that
`bun-purifier publish` uploads. Name `tests` in place of
`packages.elysia`, and pass `testScript = "test:types"` to the builder,
to type-check the tests with `tsc`. The `test:types` script is the one
to run in the sandbox, because the `test` script of elysia installs
packages from npm and the sandbox has no network.

## Credits

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo).
