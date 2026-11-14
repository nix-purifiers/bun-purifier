// SPDX-License-Identifier: MIT
import { chmodSync, cpSync, lstatSync, mkdtempSync, readFileSync, readdirSync, realpathSync, renameSync, rmSync } from "node:fs";
import { join } from "node:path";
import { parseJsonc } from "./jsonc";

// Bun applies dependency patches inside its cache. Ordinary entries can
// remain shared store links, but patched packages need private writable files.
export function writablePatches(root: string, cache: string): void {
  const lock = parseJsonc(readFileSync(join(root, "bun.lock"), "utf8")) as { patchedDependencies?: Record<string, unknown> };
  const patched = new Set(Object.keys(lock.patchedDependencies ?? {}));
  if (!patched.size) return;
  function writable(path: string): void {
    const stat = lstatSync(path);
    if (stat.isSymbolicLink()) return;
    chmodSync(path, stat.mode | 0o200);
    if (stat.isDirectory()) for (const name of readdirSync(path)) writable(join(path, name));
  }
  function visit(dir: string): void {
    for (const name of readdirSync(dir)) {
      const path = join(dir, name);
      if (!lstatSync(path).isSymbolicLink()) {
        if (lstatSync(path).isDirectory()) visit(path);
        continue;
      }
      let manifest: { name?: string; version?: string };
      try { manifest = JSON.parse(readFileSync(join(path, "package.json"), "utf8")); }
      catch (error) {
        if ((error as NodeJS.ErrnoException).code === "ENOENT") continue;
        throw error;
      }
      if (!patched.has(`${manifest.name}@${manifest.version}`) && !patched.has(manifest.name ?? "")) continue;
      const temporary = mkdtempSync(join(dir, ".writable-patch-"));
      try {
        const copy = join(temporary, "package");
        cpSync(realpathSync(path), copy, { recursive: true, verbatimSymlinks: true });
        writable(copy);
        rmSync(path);
        renameSync(copy, path);
      } finally { rmSync(temporary, { recursive: true, force: true }); }
    }
  }
  visit(cache);
}

if (import.meta.main) writablePatches(process.argv[2], process.argv[3]);
