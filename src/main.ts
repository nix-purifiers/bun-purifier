// SPDX-License-Identifier: MIT
//
// The bun-purifier command.
//
//   bun-purifier lock [--force]
//     Runs `bun install --lockfile-only`, which keeps every resolution
//     bun.lock records and writes bun.lock where it is missing or
//     incomplete, then writes bun-purifier.lock.json from bun.lock
//     (src/lock.ts).
//   bun-purifier update [--lockfile <path>] [<package>...]
//     Runs `bun update`, which resolves every package, or the named ones,
//     anew within the ranges of package.json and rewrites bun.lock, then
//     locks against the new bun.lock. `lock` keeps the resolution of
//     bun.lock as it is.
//   bun-purifier prefetch [bun install flags]
//     Builds the locked install cache with Nix, keeps it with a GC root in
//     node_modules/.cache/bun-purifier, and runs an offline `bun install`
//     from it. bun's own commands then work with no network.
//   bun-purifier publish [--package <name>] [bun publish flags]
//     Builds the package's release tarball in the Nix sandbox and runs
//     `bun publish` with it.
//
// The Nix package (pkgs/bun-purifier) runs this file with the bun the lock
// is made with, and sets BUN_PURIFIER_LIB to nix/lib and
// BUN_PURIFIER_NIXPKGS to the nixpkgs the flake pins.
//
// An external build keeps its lockfiles outside the repository. Every
// command then takes `--lockfile <path>` or BUN_PURIFIER_LOCKFILE for
// bun-purifier.lock.json, and `--tool-lockfile <path>` or
// BUN_PURIFIER_TOOL_LOCKFILE for bun.lock. With the second, each command
// works from that bun.lock, and `lock` and `update` write bun.lock there.
// The bun.lock in the tree is the same afterwards as before. When the
// outside bun.lock does not exist yet, `lock` and `update` start from the
// bun.lock in the tree.
//
// When BUN_PURIFIER_CACHE names an install cache Nix already built,
// `prefetch` installs from it and builds nothing, so it needs neither Nix
// nor the network. The offline check of the flake runs it that way in the
// sandbox.

import {
  chmodSync,
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  readlinkSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, join, relative, resolve } from "node:path";
import { withBoundNpmLock, withNpmInputs, type Repository } from "./npm-inputs";
import { writablePatches } from "./writable-patches";
import { isStale, LOCK_FILE, LockError, lock, lockedPackages, readBunLock, readLock } from "./lock";

const usage = `usage:
  bun-purifier lock [--input <Nix producer>] [--lockfile <path>] [--tool-lockfile <path>] [--force]
  bun-purifier update [--input <Nix producer>] [--lockfile <path>] [--tool-lockfile <path>] [<package>...]
  bun-purifier prefetch [--lockfile <path>] [--tool-lockfile <path>] [bun install flags]
  bun-purifier publish [--lockfile <path>] [--tool-lockfile <path>] [--package <name>] [bun publish flags]`;

// A program the command ran failed with this exit code, after printing
// its own error.
class Exit extends Error {
  constructor(readonly code: number) {
    super(`exit ${code}`);
  }
}

// The error reaches the end of the command, so the tree's bun.lock is
// restored first (withToolLockfile).
function fail(message: string): never {
  throw new LockError(message);
}

function env(name: string): string {
  return process.env[name] ?? fail(`${name} is not set; run bun-purifier through its Nix package.`);
}

// The project root: the nearest directory upward with a bun.lock. For
// `lock`, which writes bun.lock, and for a bun.lock kept outside the tree,
// it is the working directory when that holds a package.json.
function findRoot(command: string, outsideBunLock: boolean): string {
  let dir = process.cwd();
  for (;;) {
    if (existsSync(join(dir, "bun.lock")) || existsSync(join(dir, "bun.lockb"))) return dir;
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  if ((command === "lock" || outsideBunLock) && existsSync(join(process.cwd(), "package.json"))) return process.cwd();
  if (command === "tool") return "";
  fail("no bun.lock in this directory or above it.");
}

function run(argv: string[], cwd: string, setup = false, variables: Record<string, string | undefined> = process.env): void {
  const result = Bun.spawnSync(argv, { cwd, env: variables, stdout: setup ? 2 : "inherit", stderr: "inherit", stdin: "inherit" });
  if (result.exitCode !== 0) throw new Exit(result.exitCode ?? 1);
}

// Runs `body` with the bun.lock kept outside the tree in place of the
// bun.lock in the tree, and restores both source lockfiles afterwards,
// also when `body` fails. With `write`, the bun.lock that `body` leaves
// goes to the outside path.
function withToolLockfile(root: string, outside: string | undefined, write: boolean, body: () => void): void {
  if (outside === undefined) return body();
  const tree = join(root, "bun.lock");
  const saved = existsSync(tree) ? readFileSync(tree) : undefined;
  // Saving a text lock can remove bun.lockb, even with --lockfile-only.
  const binary = join(root, "bun.lockb");
  const binaryStat = lstatSync(binary, { throwIfNoEntry: false });
  const binaryLink = binaryStat?.isSymbolicLink() ? readlinkSync(binary) : undefined;
  const savedBinary = binaryStat && binaryLink === undefined ? readFileSync(binary) : undefined;
  if (existsSync(outside)) copyFileSync(outside, tree);
  else if (!write) fail(`${outside} does not exist. Run \`bun-purifier lock --tool-lockfile ${outside}\` to write it.`);
  try {
    body();
    if (write && existsSync(tree)) {
      mkdirSync(dirname(outside), { recursive: true });
      copyFileSync(tree, outside);
    }
  } finally {
    try {
      if (saved !== undefined) writeFileSync(tree, saved);
      else rmSync(tree, { force: true });
    } finally {
      rmSync(binary, { force: true });
      if (binaryLink !== undefined) symlinkSync(binaryLink, binary);
      else if (savedBinary !== undefined) {
        writeFileSync(binary, savedBinary);
        chmodSync(binary, binaryStat!.mode & 0o7777);
      }
    }
  }
}

// Leaves a bun.lock that matches the package manifests as it is. A
// missing, binary or incomplete one gets `bun install --lockfile-only`,
// which keeps every resolution bun.lock records and resolves the rest.
function completeBunLock(root: string, reconstruct = false): void {
  if (!reconstruct && existsSync(join(root, "bun.lock"))) {
    const frozen = Bun.spawnSync([process.execPath, "install", "--frozen-lockfile", "--lockfile-only", "--no-progress"], {
      cwd: root,
      stdout: "ignore",
      stderr: "ignore",
    });
    if (frozen.exitCode === 0) return;
  }
  run([process.execPath, "install", "--lockfile-only", "--save-text-lockfile", "--no-progress"], root);
}

function nixBuild(root: string, args: string[], outLink?: string): string {
  const argv = [
    "nix",
    "build",
    "--print-out-paths",
    "--file",
    join(env("BUN_PURIFIER_LIB"), "interactive.nix"),
    "--argstr",
    "nixpkgs",
    env("BUN_PURIFIER_NIXPKGS"),
    ...args,
    ...(outLink ? ["--out-link", outLink] : ["--no-link"]),
  ];
  const result = Bun.spawnSync(argv, { cwd: root, stdout: "pipe", stderr: "inherit" });
  if (result.exitCode !== 0) fail("the Nix build failed.");
  return result.stdout.toString().trim().split("\n")[0];
}

// A project without a lockfile builds from bun.lock alone, so only a
// lockfile older than bun.lock stops a command.
function requireCurrentLock(root: string, file: string): void {
  if (isStale(root, readLock(file))) {
    fail(`${basename(file)} is older than bun.lock, or was made with another bun. Run \`bun-purifier lock\`.`);
  }
}

// Takes `--lockfile <path>` and `--tool-lockfile <path>` (or the forms
// with "=") out of the arguments. Each option takes precedence over its
// variable, BUN_PURIFIER_LOCKFILE or BUN_PURIFIER_TOOL_LOCKFILE, which the
// dev shell of a packaging flake can set. Without either, the lockfile is
// bun-purifier.lock.json at the project root and the bun.lock is the one
// in the tree.
function takeLockfiles(args: string[]): { file?: string; toolFile?: string; rest: string[] } {
  const fromEnv = (name: string) => (process.env[name] ? resolve(process.env[name]!) : undefined);
  let file = fromEnv("BUN_PURIFIER_LOCKFILE");
  let toolFile = fromEnv("BUN_PURIFIER_TOOL_LOCKFILE");
  const rest: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const option = args[i].split("=")[0];
    if (option !== "--lockfile" && option !== "--tool-lockfile") {
      rest.push(args[i]);
      continue;
    }
    const value = args[i].includes("=") ? args[i].slice(option.length + 1) : args[++i];
    const path = resolve(value ?? fail(`${option} needs a path.`));
    if (option === "--lockfile") file = path;
    else toolFile = path;
  }
  return { file, toolFile, rest };
}

// Recreates the directories of a tree of links with default permissions,
// and links each of its symlinks to the same target. A recursive copy
// would keep the read-only modes of the store.
function linkTree(from: string, to: string): void {
  mkdirSync(to, { recursive: true });
  for (const name of readdirSync(from)) {
    const source = join(from, name);
    if (lstatSync(source).isSymbolicLink()) {
      symlinkSync(readlinkSync(source), join(to, name));
    } else {
      linkTree(source, join(to, name));
    }
  }
}

// Gives the owner write permission on every directory of a tree, so it
// can be removed.
function makeRemovable(dir: string): void {
  if (!existsSync(dir) || lstatSync(dir).isSymbolicLink() || !lstatSync(dir).isDirectory()) return;
  chmodSync(dir, 0o755);
  for (const name of readdirSync(dir)) makeRemovable(join(dir, name));
}

function prefetch(root: string, file: string, args: string[], views: Repository[] = [], setup = false): void {
  requireCurrentLock(root, file);
  // The Nix build's result link is a GC root, so the cache stays in the
  // store while the project uses it.
  const dir = join(root, "node_modules", ".cache", "bun-purifier");
  mkdirSync(dir, { recursive: true });
  const cache =
    process.env.BUN_PURIFIER_CACHE ||
    nixBuild(root, ["--argstr", "src", root, "--argstr", "lockFile", file, "cache"], join(dir, "result"));
  // bun writes into its cache directory: a writable copy of the tree of
  // links to the unpacked packages.
  const writable = join(dir, "bun-cache");
  makeRemovable(writable);
  rmSync(writable, { recursive: true, force: true });
  linkTree(cache, writable);
  writablePatches(root, writable);
  // Bun prioritizes this variable over --cache-dir. Keep the offline
  // install on the prepared cache even when the caller configured another.
  withBoundNpmLock(root, views, () =>
    run([process.execPath, "install", "--frozen-lockfile", "--offline", `--cache-dir=${writable}`, ...args], root, setup,
      { ...process.env, BUN_INSTALL_CACHE_DIR: writable }));
}

function publish(root: string, file: string, args: string[], composed = false): void {
  requireCurrentLock(root, file);
  const packages = lockedPackages(root, readBunLock(root));
  let name: string | undefined;
  const rest: string[] = [];
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--package") name = args[++i];
    else if (args[i].startsWith("--package=")) name = args[i].slice("--package=".length);
    else rest.push(args[i]);
  }
  if (name === undefined) {
    // The package of the working directory.
    const path = relative(root, process.cwd());
    name =
      packages.find((p) => p.path === path)?.name ??
      fail(`no package of bun.lock is at ${path || "the project root"}; name one with --package.`);
  }
  const pkg =
    packages.find((p) => p.name === name && p.version) ??
    fail(`bun.lock has no package named ${name} with a version.`);
  const out = nixBuild(root, [
    "--argstr",
    "src",
    root,
    "--argstr",
    "lockFile",
    file,
    "--argstr",
    "package",
    name!,
    composed ? "npmPublication" : "release",
  ]);
  if (composed) {
    const modules = JSON.parse(readFileSync(join(out, "catalog.json"), "utf8")).modules;
    const options = rest.some(arg => arg === "--tag" || arg.startsWith("--tag=")) ? rest : ["--tag", "nix", ...rest];
    const registryOptions: string[] = [];
    for (let index = 0; index < rest.length; index++) {
      if (["--registry", "--config", "--ca", "--cafile"].includes(rest[index])) registryOptions.push(rest[index], rest[++index]);
      else if (/^--(registry|config|ca|cafile)=/.test(rest[index])) registryOptions.push(rest[index]);
    }
    for (const item of modules.sort((a: { primary: boolean; name: string }, b: { primary: boolean; name: string }) => Number(a.primary) - Number(b.primary) || a.name.localeCompare(b.name))) {
      if (!item.primary) {
        const lookupOptions = [...registryOptions];
        if (!lookupOptions.some(arg => arg === "--registry" || arg.startsWith("--registry=")) && item.package.publishConfig?.registry)
          lookupOptions.push("--registry", item.package.publishConfig.registry);
        const existing = Bun.spawnSync([process.execPath, "info", `${item.name}@${item.version}`, "dist.integrity", "--json", "--no-cache", ...lookupOptions], {
          cwd: join(root, pkg.path), stdout: "pipe", stderr: "ignore",
        });
        if (existing.exitCode === 0) {
          const integrity = JSON.parse(existing.stdout.toString() || "null");
          if (integrity === item.integrity) continue;
          if (integrity != null) fail(`registry artifact differs from Nix input: ${item.name}@${item.version}`);
        }
      }
      run([process.execPath, "publish", join(out, item.archive), ...options], join(root, pkg.path));
    }
    return;
  }
  const tarball = readdirSync(out).find((f) => f.endsWith(".tgz")) ?? fail(`the build of ${name} made no tarball.`);
  // bun publish runs in the directory of the package, so it reads the
  // registry configuration there, as it does for a package it packs.
  run([process.execPath, "publish", join(out, tarball), ...rest], join(root, pkg.path));
}

const toolWrapper = process.env.BUN_PURIFIER_TOOL_WRAPPER === "1";
delete process.env.BUN_PURIFIER_TOOL_WRAPPER;
const [command, ...argv] = toolWrapper ? ["tool", ...process.argv.slice(2)] : process.argv.slice(2);
try {
  const references: string[] = [];
  const remaining: string[] = [];
  for (let index = 0; index < argv.length; index++) {
    if (!toolWrapper && argv[index] === "--input") {
      if (!argv[index + 1]) fail("--input needs a Nix producer reference");
      references.push(argv[++index]);
    } else remaining.push(argv[index]);
  }
  const { file: givenFile, toolFile, rest: args } = takeLockfiles(toolWrapper ? [] : remaining);
  if (toolWrapper) args.push(...remaining);
  const root = command === undefined || command === "--help" ? "" : findRoot(command, toolFile !== undefined);
  if (toolWrapper && !root) {
    console.error("bun-purifier: no lockfile; using ordinary, impure Bun resolution.");
    run([process.execPath, ...args], process.cwd());
    process.exit(0);
  }
  if (command === undefined || command === "--help") {
    console.error(usage);
    process.exit(0);
  }
  const file = givenFile ?? join(root, LOCK_FILE);
  const report = (outcome: "wrote" | "current" | "none") =>
    console.error(
      outcome === "wrote"
        ? `bun-purifier: wrote ${file}`
        : outcome === "current"
          ? `bun-purifier: ${basename(file)} is current.`
          : "bun-purifier: bun.lock records everything the Nix build needs, so there is no lockfile to write.",
    );
  let previousInputs: unknown[] = [];
  if (file && existsSync(file)) {
    try { previousInputs = readLock(file)?.projectInputs ?? []; }
    catch (error) {
      if (!(command === "lock" && args.includes("--force"))) throw error;
    }
  }
  let context: { projectInputs: unknown[]; views: { repository: string; catalog: string }[] } = { projectInputs: [], views: [] };
  if (references.length || previousInputs.length) {
    const result = Bun.spawnSync([
      env("BUN_PURIFIER_PYTHON"), join(import.meta.dir, "project-inputs.py"),
      file, join(root, "node_modules/.cache/bun-purifier/inputs"),
      JSON.stringify(references.length ? references : null), String(command === "update"),
    ], { stdout: "pipe", stderr: "inherit" });
    if (result.exitCode !== 0) throw new Exit(result.exitCode ?? 1);
    context = JSON.parse(result.stdout.toString());
  }
  const mutatingTool = toolWrapper && ["add", "remove", "rm", "update"].includes(args[0]);
  withNpmInputs(root, command === "publish" ? [] : context.views, (portableLock) => {
  switch (command) {
    case "tool":
      if (mutatingTool) {
        withToolLockfile(root, toolFile, true, () => {
          run([process.execPath, ...args], process.cwd());
          report(lock(root, file, { bun: process.execPath, projectInputs: context.projectInputs, portableLock }));
        });
      } else if (args[0] === "install" || args[0] === "i") {
        withToolLockfile(root, toolFile, false, () => prefetch(root, file, args.slice(1), context.views));
      } else {
        withToolLockfile(root, toolFile, false, () => {
          if (["run", "test", "build", "x"].includes(args[0])) prefetch(root, file, [], context.views, true);
          run([process.execPath, ...args], process.cwd());
        });
      }
      break;
    case "lock":
      withToolLockfile(root, toolFile, true, () => {
        completeBunLock(root, context.views.length > 0);
        report(lock(root, file, { force: args.includes("--force"), bun: process.execPath, projectInputs: context.projectInputs, portableLock }));
      });
      break;
    case "update":
      withToolLockfile(root, toolFile, true, () => {
        run([process.execPath, "update", ...args], root);
        report(lock(root, file, { bun: process.execPath, projectInputs: context.projectInputs, portableLock }));
      });
      break;
    case "prefetch":
      withToolLockfile(root, toolFile, false, () => prefetch(root, file, args, context.views));
      break;
    case "publish":
      withToolLockfile(root, toolFile, false, () => publish(root, file, args, context.projectInputs.length > 0));
      break;
    default:
      console.error(usage);
      throw new Exit(2);
  }
  }, mutatingTool);
} catch (e) {
  if (e instanceof LockError) {
    console.error(`bun-purifier: ${e.message}`);
    process.exit(1);
  }
  if (e instanceof Exit) process.exit(e.code);
  throw e;
}
