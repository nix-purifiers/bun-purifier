const result = await Bun.build({ entrypoints: ["src/index.ts"], outdir: "dist", target: "bun" })
if (!result.success) throw new AggregateError(result.logs, "build failed")
