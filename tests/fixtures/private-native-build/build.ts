import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
const manifest = JSON.parse(readFileSync("package.json", "utf8"));
const result = await Bun.build({ entrypoints: ["./index.ts"], outdir: "./dist", target: "bun" });
if (!result.success) throw new AggregateError(result.logs, "native fixture build failed");
mkdirSync("dist", { recursive: true });
// The native publication transform bundles the private workspace. Its package
// version comes from the source manifest, and its runtime dependencies are bundled.
writeFileSync("dist/package.json", JSON.stringify({
  name: manifest.name,
  version: manifest.version,
  type: manifest.type,
  exports: "./index.js",
}, null, 2) + "\n");
