// SPDX-License-Identifier: MIT
import { pathToFileURL } from "node:url";

if (typeof Bun === "undefined" || typeof Bun.version !== "string" ||
    typeof Bun.spawnSync !== "function") {
  console.error("bun-purifier: selected runtime must provide Bun.version and Bun.spawnSync.");
  process.exit(1);
}

// Validate and start the CLI in one process, without running project
// preload hooks an extra time just to probe the selected runtime.
process.argv.splice(1, 1);
await import(pathToFileURL(process.argv[1]).href);
