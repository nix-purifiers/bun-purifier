// SPDX-License-Identifier: MIT
//
// `bun-purifier lock`: records in bun-purifier.lock.json what Nix needs to
// build from bun.lock and cannot find in it.
//
// bun.lock names every downloaded package with its URL and integrity
// hash, and Nix reads it (nix/lib/bun-lock.nix). What bun.lock leaves out
// is where bun keeps each package in its install cache, for the packages
// whose cache names bun derives with internal hashes (prerelease versions,
// tarball URLs); the NAR hash of a git checkout; which packages bun
// installs on no system the nix-purifiers build for; and the default
// registry when it comes from the environment or configuration in the
// home directory. The lock run finds the cache names out: it installs a
// copy of the project into an empty cache once per system, and reads the
// names bun gave the entries.
//
// The lockfile holds only those facts. When there are none, the lock
// writes no lockfile, and Nix builds from bun.lock alone.

import { createHash } from "node:crypto";
import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, join, normalize, relative, resolve } from "node:path";
import { parseJsonc } from "./jsonc";

// nix/lib/lock-version.nix holds the same number.
export const LOCK_VERSION = 3;
export const LOCK_FILE = "bun-purifier.lock.json";

const NPM_REGISTRY = "https://registry.npmjs.org/";

// The bun platforms of the Nix systems the nix-purifiers build for,
// x86_64-linux, aarch64-linux and aarch64-darwin, as the `admits` of the
// shared library maps them.
const PLATFORMS: [os: string, cpu: string][] = [
  ["linux", "x64"],
  ["linux", "arm64"],
  ["darwin", "arm64"],
];

type Meta = { os?: string | string[]; cpu?: string | string[] };

// The facts of a lock, as nix/lib/lock.nix reads them.
export type Facts = {
  // The default registry, when it is not the npm registry.
  defaultRegistry?: string;
  // The cache path of each package whose path nix/lib/lock.nix cannot
  // derive from bun.lock, by bun.lock key.
  cachePaths: Record<string, string>;
  // The NAR hash of each git checkout, by bun.lock key.
  gitHashes: Record<string, string>;
  // The bun.lock keys of packages bun installs on no system the
  // nix-purifiers build for, among those that their platform filters do
  // not exclude already.
  notInstalled: string[];
};

export type Lock = Facts & {
  version: number;
  bunVersion: string;
  bunLockHash: string;
  contentHash: string;
  projectInputs?: unknown[];
};

export type LockedPackage = {
  path: string;
  name?: string;
  version?: string;
  bin?: string | Record<string, string>;
};

// JSON as Nix's builtins.toJSON writes it: object keys sorted, no
// whitespace.
export function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value !== null && typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>)
      .filter(([, v]) => v !== undefined)
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
    return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${canonicalJson(v)}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

// The digest of a lockfile, over everything but `contentHash` itself.
// nix/lib/lock.nix recomputes it to tell a lockfile edited after the lock.
export function contentHash(lock: Omit<Lock, "contentHash"> | Lock): string {
  const { contentHash: _, ...rest } = lock as Lock;
  return createHash("sha256").update(canonicalJson(rest)).digest("hex");
}

// SHA-256 of bun.lock, which nix/lib/lock.nix recomputes to tell a stale
// lock.
export function bunLockHash(root: string): string {
  return createHash("sha256").update(readFileSync(join(root, "bun.lock"))).digest("hex");
}

export type BunLock = {
  lockfileVersion: number;
  workspaces: Record<string, unknown>;
  packages: Record<string, unknown[]>;
};

export class LockError extends Error {}

export function readBunLock(root: string): BunLock {
  const file = join(root, "bun.lock");
  if (!existsSync(file)) {
    if (existsSync(join(root, "bun.lockb"))) {
      throw new LockError(
        "this project has the binary bun.lockb. Run `bun install --save-text-lockfile` to write bun.lock, then lock again.",
      );
    }
    throw new LockError(`no bun.lock in ${root}. Run \`bun install\` first.`);
  }
  return parseJsonc(readFileSync(file, "utf8")) as BunLock;
}

function manifestPath(path: string): string {
  return path === "" ? "package.json" : `${path}/package.json`;
}

// The packages of the project: the workspaces of bun.lock, with the fields
// of their manifests. nix/lib/lock.nix reads them the same way.
export function lockedPackages(root: string, bunLock: BunLock): LockedPackage[] {
  return Object.keys(bunLock.workspaces)
    .sort((a, b) => a.localeCompare(b))
    .map((path) => {
      const manifest = JSON.parse(readFileSync(join(root, manifestPath(path)), "utf8"));
      const pkg: LockedPackage = { path };
      if (typeof manifest.name === "string") pkg.name = manifest.name;
      if (typeof manifest.version === "string") pkg.version = manifest.version;
      if (manifest.bin !== undefined) pkg.bin = manifest.bin;
      return pkg;
    });
}

function bunfigRegistry(file: string): string | undefined {
  if (!existsSync(file)) return undefined;
  const config = Bun.TOML.parse(readFileSync(file, "utf8")) as {
    install?: { registry?: string | { url?: string } };
  };
  const registry = config.install?.registry;
  return typeof registry === "string" ? registry : registry?.url;
}

// The `registry=` line of an .npmrc, with `${VAR}` references expanded
// from the environment as npm and bun expand them.
function npmrcRegistry(file: string): string | undefined {
  if (!existsSync(file)) return undefined;
  for (const line of readFileSync(file, "utf8").split("\n")) {
    const match = /^\s*registry\s*=\s*(.+?)\s*$/.exec(line);
    if (match) return match[1].replace(/\$\{([^}]+)\}/g, (_, name) => process.env[name] ?? "");
  }
  return undefined;
}

// The registry bun installs unscoped packages from when bun.lock names
// none, from the same sources bun reads, first match winning: the
// BUN_CONFIG_REGISTRY and NPM_CONFIG_REGISTRY variables, the project's
// bunfig.toml and .npmrc, the user's .bunfig.toml and .npmrc, and else the
// npm registry. A scoped package needs none of this: bun.lock records the
// tarball URL of every package from a registry other than the default.
export function defaultRegistry(root: string): string {
  // bun and npm find the user's files through HOME.
  const home = process.env.HOME || homedir();
  const xdg = process.env.XDG_CONFIG_HOME ?? join(home, ".config");
  const url =
    process.env.BUN_CONFIG_REGISTRY ||
    process.env.NPM_CONFIG_REGISTRY ||
    process.env.npm_config_registry ||
    bunfigRegistry(join(root, "bunfig.toml")) ||
    npmrcRegistry(join(root, ".npmrc")) ||
    bunfigRegistry(join(xdg, ".bunfig.toml")) ||
    bunfigRegistry(join(home, ".bunfig.toml")) ||
    npmrcRegistry(join(home, ".npmrc")) ||
    NPM_REGISTRY;
  return url.endsWith("/") ? url : `${url}/`;
}

// The URL Nix fetches a git dependency from. The sandbox has no SSH keys,
// so an SSH URL becomes the HTTPS URL of the same repository, which is
// what bun falls back to as well. nix/lib/lock.nix has the same rule.
export function gitFetchUrl(resolution: string): string {
  const url = resolution.replace(/^git\+/, "").replace(/#.*$/, "");
  const ssh = /^ssh:\/\/(?:[^@/]+@)?([^/:]+)(?::\d+)?\/(.+)$/.exec(url);
  if (ssh) return `https://${ssh[1]}/${ssh[2]}`;
  const scp = /^(?:[^@/]+@)?([^/:]+):(?!\/)(.+)$/.exec(url);
  if (scp && !/^[a-z]+:\/\//.test(url)) return `https://${scp[1]}/${scp[2]}`;
  return url;
}

// The NAR hash of a git checkout without submodules, as nixpkgs' fetchgit
// computes it. bun clones without submodules (a bare clone, then a
// checkout of the commit), so the entry says `submodules: false`.
function gitHash(url: string, rev: string): string {
  const run = Bun.spawnSync(["nix-prefetch-git", "--url", url, "--rev", rev, "--quiet"], {
    stdout: "pipe",
    stderr: "inherit",
  });
  if (run.exitCode !== 0) throw new LockError(`nix-prefetch-git could not fetch ${url} at ${rev}.`);
  return JSON.parse(run.stdout.toString()).hash;
}

// bun leaves the host out of the cache name of a package from the npm
// registry.
export function cacheHost(registryUrl: string): string {
  const host = new URL(registryUrl).host;
  return host === "registry.npmjs.org" ? "" : host;
}

// The package names and versions of a cache's entries, by kind. Entry
// names of downloaded archives end in `@@@<cache version>`, and a scoped
// package's entry sits in a directory named for its scope. A git checkout
// is `@G@<commit>`.
export type Observed = {
  registry: Map<string, string>; // `${name}@${version}@@${host}` -> path
  github: Map<string, string>; // resolution id -> path
  tarball: Map<string, string[]>; // package name -> paths
  git: Map<string, string>; // commit -> path
};

export function observe(cache: string): Observed {
  const observed: Observed = { registry: new Map(), github: new Map(), tarball: new Map(), git: new Map() };
  const entries: string[] = [];
  for (const name of readdirSync(cache)) {
    if (name.startsWith("@G@")) {
      observed.git.set(name.slice(3), name);
    } else if (/@@@\d+$/.test(name)) {
      entries.push(name);
    } else if (name.startsWith("@") && !name.includes("@@")) {
      for (const inner of readdirSync(join(cache, name))) {
        if (/@@@\d+$/.test(inner)) entries.push(`${name}/${inner}`);
      }
    }
  }
  for (const path of entries) {
    const entry = basename(path).replace(/@@@\d+$/, "");
    if (entry.startsWith("@GH@")) {
      observed.github.set(entry.slice(4), path);
      continue;
    }
    const manifestFile = join(cache, path, "package.json");
    if (!existsSync(manifestFile)) continue;
    const manifest = JSON.parse(readFileSync(manifestFile, "utf8"));
    if (entry.startsWith("@T@")) {
      const paths = observed.tarball.get(manifest.name) ?? [];
      observed.tarball.set(manifest.name, [...paths, path]);
      continue;
    }
    const host = entry.includes("@@") ? entry.slice(entry.indexOf("@@") + 2) : "";
    observed.registry.set(`${manifest.name}@${manifest.version}@@${host}`, path);
  }
  return observed;
}

// The path of a dependency on a local directory or tarball, relative to
// the project root, or undefined for any other dependency. bun.lock
// writes a directory as `file:<path>` and a tarball as the bare path.
export function localPath(resolution: string): string | undefined {
  if (resolution.startsWith("file:")) return normalize(resolution.slice("file:".length));
  if (/^(\.\.?\/|\/)/.test(resolution)) return normalize(resolution);
  return undefined;
}

// The local dependencies outside the project, relative to the project
// root.
export function outsidePaths(bunLock: BunLock): string[] {
  const paths = new Set<string>();
  for (const entry of Object.values(bunLock.packages)) {
    const path = localPath(splitKey(entry[0] as string)[1]);
    if (path !== undefined && (path === ".." || path.startsWith("../") || path.startsWith("/"))) {
      paths.add(path);
    }
  }
  return [...paths].sort();
}

// Copies the project, and each `file:` dependency outside it at the same
// place relative to it, into `work`. Returns the copy of the project.
export function copyProject(root: string, bunLock: BunLock, work: string): string {
  const outside = outsidePaths(bunLock).map((p) => resolve(root, p)).filter((p) => !p.startsWith("/nix/store/"));
  // The deepest directory that holds the project and every outside path.
  let anchor = root;
  while (outside.some((p) => relative(anchor, p).startsWith(".."))) anchor = dirname(anchor);
  const filter = (src: string) => {
    const name = basename(src);
    return name !== "node_modules" && name !== ".git";
  };
  for (const dir of [root, ...outside]) {
    cpSync(dir, join(work, "source", relative(anchor, dir)), { recursive: true, filter });
  }
  return join(work, "source", relative(anchor, root));
}

function lockRun(root: string, bunLock: BunLock, bun: string): string {
  const work = mkdtempSync(join(tmpdir(), "bun-purifier-lock-"));
  const cache = join(work, "cache");
  const project = copyProject(root, bunLock, work);
  for (const [os, cpu] of PLATFORMS) {
    const run = Bun.spawnSync(
      [
        bun,
        "install",
        "--frozen-lockfile",
        "--ignore-scripts",
        "--no-progress",
        `--cache-dir=${cache}`,
        `--os=${os}`,
        `--cpu=${cpu}`,
      ],
      { cwd: project, stdout: "inherit", stderr: "inherit" },
    );
    if (run.exitCode !== 0) {
      rmSync(work, { recursive: true, force: true });
      // The lock run installs with --frozen-lockfile, which fails when
      // bun.lock no longer matches the package manifests.
      throw new LockError(
        `the lock run's \`bun install --frozen-lockfile\` for ${os}-${cpu} failed (its output is above). If bun.lock is out of date with package.json, run \`bun install\`, then lock again.`,
      );
    }
  }
  return work;
}

// Splits a bun.lock package key, `<name>@<resolution>`, where a scoped
// name starts with "@" itself.
export function splitKey(key: string): [name: string, resolution: string] {
  const at = key.indexOf("@", key.startsWith("@") ? 1 : 0);
  return [key.slice(0, at), key.slice(at + 1)];
}

// Whether a package with npm's `os` and `cpu` filters installs on one of
// the systems, as the `admits` of the shared library decides.
function admitsAnyPlatform(meta: Meta): boolean {
  const admits = (field: string | string[] | undefined, value: string) => {
    const entries = field === undefined ? [] : Array.isArray(field) ? field : [field];
    if (entries.length === 0 || (entries.length === 1 && entries[0] === "any")) return true;
    const exclusions = entries.filter((e) => e.startsWith("!"));
    const inclusions = entries.filter((e) => !e.startsWith("!"));
    return !exclusions.includes(`!${value}`) && (inclusions.length === 0 || inclusions.includes(value));
  };
  return PLATFORMS.some(([os, cpu]) => admits(meta.os, os) && admits(meta.cpu, cpu));
}

// The facts of bun.lock that Nix needs and cannot derive, from the cache
// the lock run filled. nix/lib/lock.nix derives the cache path of a
// registry package as `<name>@<version>[@@<host>]@@@1`, of a GitHub
// tarball as `@GH@<id>@@@1` and of a git checkout as `@G@<commit>`; the
// facts record each path that differs, and every tarball URL. A package
// the lock run left out of the cache is one bun needs on no system, such
// as a dependency of a WebAssembly fallback. Every entry the lock run put
// in the cache has to match a package of bun.lock; one that matches none
// means bun-purifier computed a cache name differently from bun.
export function facts(root: string, bunLock: BunLock, observed: Observed): Facts {
  const registry = defaultRegistry(root);
  const result: Facts = { cachePaths: {}, gitHashes: {}, notInstalled: [] };
  if (registry !== NPM_REGISTRY) result.defaultRegistry = registry;
  const used = new Set<string>();
  // bun also extracts a local tarball into a `@T@` cache entry. That entry
  // belongs to the source, so it is not a download.
  const localTarballs = new Set<string>();
  // bun.lock keys a package by where it sits in the dependency tree, so two
  // keys can name the same version, which bun keeps in one cache entry.
  const hashByPath = new Map<string, string>();

  for (const [key, entry] of Object.entries(bunLock.packages).sort(([a], [b]) => a.localeCompare(b))) {
    const [name, resolution] = splitKey(entry[0] as string);
    if (/^(workspace|root):/.test(resolution) || localPath(resolution) !== undefined) {
      if (localPath(resolution) !== undefined && !resolution.startsWith("file:")) localTarballs.add(name);
      continue;
    }
    if (resolution.startsWith("link:")) {
      throw new LockError(
        `${key} is a link: dependency. It names a package registered with \`bun link\` in bun's global directory on this machine, and bun.lock records only the name, so no other machine and no Nix build can resolve it. Depend on the package with file: and its path instead.`,
      );
    }
    let derived: string | undefined;
    let path: string | undefined;
    let meta: Meta;
    let integrity: unknown;
    if (/^git(\+|:)/.test(resolution)) {
      // [key, meta, commit]
      const rev = entry[2] as string;
      derived = `@G@${rev}`;
      path = observed.git.get(rev);
      meta = entry[1] as Meta;
      if (path !== undefined) result.gitHashes[key] = gitHash(gitFetchUrl(resolution), rev);
      integrity = "";
    } else if (resolution.startsWith("github:")) {
      // [key, meta, resolution id, integrity]
      derived = `@GH@${entry[2]}@@@1`;
      path = observed.github.get(entry[2] as string);
      meta = entry[1] as Meta;
      integrity = entry[3];
    } else if (/^https?:\/\//.test(resolution)) {
      // [key, meta, integrity]; bun names the entry with a hash of the URL.
      const paths = observed.tarball.get(name) ?? [];
      if (paths.length > 1) {
        throw new LockError(`${name} comes from more than one tarball URL, and bun-purifier cannot tell their cache entries apart.`);
      }
      path = paths[0];
      meta = entry[1] as Meta;
      integrity = entry[2];
    } else {
      // [key, registry tarball URL or "", meta, integrity]
      const tarball = entry[1] as string;
      const host = cacheHost(tarball !== "" ? tarball : registry);
      derived = `${name}@${resolution}${host === "" ? "" : `@@${host}`}@@@1`;
      path = observed.registry.get(`${name}@${resolution}@@${host}`);
      meta = entry[2] as Meta;
      integrity = entry[3];
    }
    if (path === undefined) {
      // Nix leaves out what the platform filters exclude by itself.
      if (admitsAnyPlatform(meta ?? {})) result.notInstalled.push(key);
      continue;
    }
    if (typeof integrity !== "string") {
      throw new LockError(`bun.lock has no integrity hash for ${key}. Run \`bun install --force\` to rewrite bun.lock, then lock again.`);
    }
    const previous = hashByPath.get(path);
    if (previous !== undefined && previous !== integrity) {
      throw new LockError(
        `bun.lock has two entries for the cache entry ${path} with different hashes. Run \`bun install --force\` to rewrite bun.lock, then lock again.`,
      );
    }
    hashByPath.set(path, integrity);
    used.add(path);
    if (path !== derived) result.cachePaths[key] = path;
  }

  const fromSource = new Set([...localTarballs].flatMap((name) => observed.tarball.get(name) ?? []));
  const unmatched = observedPaths(observed).filter((p) => !used.has(p) && !fromSource.has(p));
  if (unmatched.length > 0) {
    throw new LockError(
      `the lock run installed packages that match no entry of bun.lock under the registry ${registry}: ${unmatched.join(", ")}. If bun installs from another default registry, set it in bunfig.toml or .npmrc.`,
    );
  }
  return result;
}

function observedPaths(observed: Observed): string[] {
  return [
    ...observed.registry.values(),
    ...observed.github.values(),
    ...[...observed.tarball.values()].flat(),
    ...observed.git.values(),
  ];
}

// Whether the facts hold anything Nix cannot derive from bun.lock.
export function hasFacts(f: Facts): boolean {
  return (
    f.defaultRegistry !== undefined ||
    Object.keys(f.cachePaths).length > 0 ||
    Object.keys(f.gitHashes).length > 0 ||
    f.notInstalled.length > 0
  );
}

// Reads the lockfile at `file`, or undefined when there is none. A
// lockfile that cannot be used throws an error that says what to run.
export function readLock(file: string): Lock | undefined {
  if (!existsSync(file)) return undefined;
  const name = basename(file);
  const text = readFileSync(file, "utf8");
  if (/^<<<<<<< /m.test(text)) {
    throw new LockError(
      `${name} has merge conflict markers. Resolve the conflict in bun.lock, then run \`bun-purifier lock --force\` to rewrite ${name}.`,
    );
  }
  let lock: Lock;
  try {
    lock = JSON.parse(text) as Lock;
  } catch {
    throw new LockError(`${name} is not valid JSON. Run \`bun-purifier lock --force\` to rewrite it.`);
  }
  if (lock.version !== LOCK_VERSION) {
    throw new LockError(
      `${name} has lock format version ${lock.version}; this bun-purifier writes version ${LOCK_VERSION}. Run \`bun-purifier lock --force\`.`,
    );
  }
  if (contentHash(lock) !== lock.contentHash) {
    throw new LockError(
      `the content of ${name} does not match the digest \`bun-purifier lock\` recorded, so the file was edited after the lock. Run \`bun-purifier lock --force\` to rewrite it.`,
    );
  }
  return lock;
}

// Whether a lockfile still holds for bun.lock. A project without a
// lockfile has no facts that could go stale.
export function isStale(root: string, lock: Lock | undefined): boolean {
  if (lock === undefined) return false;
  return lock.bunVersion !== Bun.version || lock.bunLockHash !== bunLockHash(root);
}

// Records the facts of the project in the lockfile at `file`, or removes
// the lockfile when there are none. A current lockfile stays as it is
// unless `force`. Returns what happened.
export function lock(
  root: string,
  file: string,
  options: { force?: boolean; bun: string; projectInputs?: unknown[]; portableLock?: () => void },
): "wrote" | "current" | "none" {
  const bunLock = readBunLock(root);
  // --force rewrites a lockfile that cannot be read, which is what the
  // errors of readLock tell the user to run.
  if (!options.force) {
    const current = readLock(file);
    if (current !== undefined && !isStale(root, current) && canonicalJson(current.projectInputs ?? []) === canonicalJson(options.projectInputs ?? [])) return "current";
  }
  const work = lockRun(root, bunLock, options.bun);
  try {
    const found = facts(root, bunLock, observe(join(work, "cache")));
    if (!hasFacts(found) && !options.projectInputs?.length) {
      rmSync(file, { force: true });
      return "none";
    }
    options.portableLock?.();
    const content = {
      version: LOCK_VERSION,
      bunVersion: Bun.version,
      bunLockHash: bunLockHash(root),
      ...found,
      ...(options.projectInputs?.length ? { projectInputs: options.projectInputs } : {}),
    };
    const result: Lock = { ...content, contentHash: contentHash(content) };
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file,`${JSON.stringify(result, null, 2)}\n`);
    return "wrote";
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}
