// SPDX-License-Identifier: MIT
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { lockedPackages, readBunLock } from "./lock";

// Development-only workspaces need not publish a version. Bun tries to
// resolve their workspace ranges even when packing a different package.
// Omit only these unpublishable dev references from the temporary pack
// manifest, and preserve the project's original manifest byte for byte.
const [root, directory, destination] = process.argv.slice(2);
const unversioned = new Set(lockedPackages(root, readBunLock(root))
  .filter(pkg => pkg.name && !pkg.version).map(pkg => pkg.name));
const file = join(root, directory, "package.json");
const original = readFileSync(file, "utf8");
const manifest = JSON.parse(original);
let changed = false;
for (const [name, range] of Object.entries(manifest.devDependencies ?? {})) {
  if (typeof range === "string" && range.startsWith("workspace:") && unversioned.has(name)) {
    delete manifest.devDependencies[name];
    changed = true;
  }
}
let status = 1;
try {
  if (changed) writeFileSync(file, JSON.stringify(manifest, null, 2) + "\n");
  const result = Bun.spawnSync([process.execPath, "pm", "pack", "--ignore-scripts", "--quiet", "--destination", destination], {
    cwd: join(root, directory), stdout: "inherit", stderr: "inherit",
  });
  status = result.exitCode ?? 1;
} finally {
  if (changed) writeFileSync(file, original);
}
process.exit(status);
