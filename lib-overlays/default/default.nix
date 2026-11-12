# SPDX-License-Identifier: MIT
#
# The `bun-purifier` library namespace: `readLock`
# (read-lock.nix), on the `purifier` namespace of the shared
# nix-purifiers library. The builder needs a package set, so it is the
# package `buildBunProject` that the default package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    bun-purifier = (prev.bun-purifier or { }) // {
      readLock = import ./read-lock.nix {
        lib = final;
        inherit (final) purifier;
      };
    };
  };

}
