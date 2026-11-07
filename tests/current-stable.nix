# SPDX-License-Identifier: MIT
# A separate, immutable upstream SDK lane; the packaged SDK stays unchanged.
{
  pkgs,
  readLock,
  realWorld,
}:
let
  assets = {
    x86_64-linux = {
      name = "bun-linux-x64-baseline";
      hash = "sha256:e0446eb55995772eb9894bebae9a6be368d985a8b9271ee124486f9946eedd76";
    };
    aarch64-linux = {
      name = "bun-linux-aarch64";
      hash = "sha256:baa6bb36f51d6e58561e02bbea825038a9df454f673d6d776e8bbf86f8c7850e";
    };
    aarch64-darwin = {
      name = "bun-darwin-aarch64";
      hash = "sha256:c240d7f0ccb90c263a849fcdb09b7ee62630d921348ed6aafda86b9d577bc510";
    };
  };
  asset = assets.${pkgs.stdenv.hostPlatform.system};
  latest = pkgs.extend (
    final: prev: {
      bun = prev.bun.overrideAttrs {
        version = "1.4.4";
        src = final.fetchurl {
          url = "https://github.com/oven-sh/bun/releases/download/bun-v1.4.4/${asset.name}.zip";
          inherit (asset) hash;
        };
      };
    }
  );
  suite = import ./default.nix {
    pkgs = latest;
    inherit readLock realWorld;
    sourcesLockFile = ./current-stable/sources.lock.json;
    bun-purifier = latest.bun-purifier.bun-purifier;
  };
in
pkgs.lib.mapAttrs' (name: value: pkgs.lib.nameValuePair "current-stable-${name}" value) (
  pkgs.lib.getAttrs [
    "unit"
    "elysia"
    "conformance-offline"
    "conformance-rebuild"
    "workspace-project"
    "workspace-program"
    "workspace-tests"
    "sources-program"
    "paths-program"
    "registries-program"
  ] suite
)
// {
  current-stable-runtime = latest.runCommand "bun-current-stable-runtime" { } ''
    test "$(${latest.bun}/bin/bun --version)" = 1.4.4
    ${latest.bun}/bin/bun -e 'if (Bun.version !== "1.4.4" || process.platform !== "${
      if pkgs.stdenv.hostPlatform.isDarwin then "darwin" else "linux"
    }" || process.arch !== "${
      if pkgs.stdenv.hostPlatform.isx86_64 then "x64" else "arm64"
    }") throw new Error("wrong SDK/platform"); console.log(JSON.stringify({version:Bun.version,revision:Bun.revision,platform:process.platform,arch:process.arch}))' > "$out"
  '';
}
