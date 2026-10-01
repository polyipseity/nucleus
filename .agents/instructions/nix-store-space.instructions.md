---
description: "Use when changing Nix store policy, GC thresholds, script bundling, or store-space audits in nucleus. Documents rejected approaches, host filesystem limits, bundleDefault policy, and GC semantics."
name: "Nix Store Space"
applyTo: "src/modules/posix/base.nix, src/modules/configs/nix/**, src/flake.nix, src/modules/lib/script-tree.nix, src/modules/lib/gc-options.nix, scripts/gc.sh, src/scripts/cleanup-nix-build-artifacts.sh, src/scripts/services/duperemove-store.sh, src/scripts/services/nix-store-gc.sh"
---

# Nix store space policy

## Store settings

Settings live in [`posix/base.nix`](../../src/modules/posix/base.nix) (NixOS `nix.settings`) and [`nix.custom.conf`](../../src/modules/configs/nix/nix.custom.conf) on MacBook (`nix.enable = false` under Determinate Nix). Read them there instead of trusting a copy. `min-free`/`max-free` are GC pressure thresholds; the `apply.sh` `health-check` `--min-free-bytes` (16 GB) is a separate system-wide check and not the same number.

Two invariants are invisible in those files. `keep-derivations`/`keep-outputs` stay `true` because `nix-shell` and rollback need them. GC is age-based (`nix-collect-garbage --delete-older-than` in `posix/base.nix`, [`nix-store-gc.sh`](../../src/scripts/services/nix-store-gc.sh), [`gc.sh`](../../scripts/gc.sh)), never `-d`.

Generation retention keeps the newest `generationsKeep` (default 7) and anything newer than `expiry` (default 7d), configured in [`gc-options.nix`](../../src/modules/lib/gc-options.nix) and overridable through `NUCLEUS_GC_GENERATIONS_KEEP` / `NUCLEUS_GC_EXPIRY` or the `nucleus-gc` flags.

Scheduling: daily `nixStoreGc` runs `nix-store-gc.sh`; weekly `gc-weekly` runs `gc.sh` as root plus the user homedir via `sudo -u`.

Host `/nix`: MacBook is the APFS volume (Determinate). NixOS is Btrfs `@nix` ([`disks.nix`](../../src/hosts/NixOS/hardware/disks.nix), [`btrfs-options.nix`](../../src/hosts/NixOS/btrfs-options.nix)) with `compress-force=zstd` and `noatime`; the NixOS guest image uses the same layout ([`src/vms/NixOS/formats/`](../../src/vms/NixOS/formats/)).

## Btrfs measurement and maintenance

`compress-force=zstd` on `@` and `@nix` forces on substituted paths ([nix#3550](https://github.com/NixOS/nix/issues/3550)), so `df` and `du` under-report. Measure with `compsize` or `btdu`.

NixOS runs `duperemove` weekly over `/nix/store` from `gc-weekly` through `gc.sh` into [`duperemove-store.sh`](../../src/scripts/services/duperemove-store.sh) with `--hashfile=/var/lib/duperemove/hashfile`. `nucleus-gc --no-duperemove-gc` opts out.

## `$out` layout and runtime copies

`writeNucleusShellApplication` ([`flake.nix`](../../src/flake.nix)) puts `scripts` and `src` under `$out` with the entry at `$out/<scriptName>.sh`, and sets no `bundleDefault`. Each app symlinks the shared derivations, so the tree is not duplicated per app. Call-site rules are in [`nix-authoring.instructions.md`](nix-authoring.instructions.md).

| Host | Store FS | Reflink at runtime |
| ---- | -------- | ------------------ |
| MacBook | APFS (`/nix` volume) | `copy_with_reflink` in `lib.sh` for wallpaper and VM images |
| NixOS | Btrfs `@nix` | `copy_with_reflink` for wallpaper and VM qcow |
| Windows | No Nix store | N/A |

Two deliberate exceptions. `equaliser` and `camillagui-backend` ship self-contained `.app` bundles and must be copied, never symlinked, because macOS app isolation and code signing break on a symlink. `core.nix` registers the same `pkgs.<attr>` in `environment.systemPackages` and `home.packages` to get one store path with dual PATH entries.

## Rejected

| Item | Why |
| ---- | --- |
| `keep-derivations` / `keep-outputs = false` | breaks `nix-shell` and rollback |
| `nix store optimise` after every rebuild | too slow; `auto-optimise-store` plus `nix.optimise.automatic` covers it |
| `nix-collect-garbage -d` | destructive; age-based GC exists |

## Store audit

Opt in with `--store-audit` or `NUCLEUS_HEALTH_CHECK_STORE_AUDIT=1`. Duplicate checkouts each pin a `.direnv/flake-inputs` GC root, so a store that will not shrink usually means stale repos: consolidate them or run `nucleus-gc`.
