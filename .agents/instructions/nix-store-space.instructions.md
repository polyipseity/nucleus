---
description: "Use when changing Nix store policy, GC thresholds, script bundling, or store-space audits in nucleus. Documents rejected approaches, host filesystem limits, bundleDefault policy, and GC semantics."
name: "Nix Store Space"
applyTo: "src/modules/posix/base.nix, src/modules/configs/nix/**, src/flake.nix, src/modules/lib/script-tree.nix, src/modules/lib/gc-options.nix, scripts/gc.sh, src/scripts/cleanup-nix-build-artifacts.sh, src/scripts/services/duperemove-store.sh, src/scripts/services/nix-store-gc.sh"
---

# Nix store space policy

Store settings live in `posix/base.nix` and `nix.custom.MacBook.conf`; read them there. `keep-derivations` and `keep-outputs` stay true, GC is age-based (`nix-collect-garbage --delete-older-than`), never `-d`. The health-check `--min-free-bytes` (16 GB) is a separate check. Retention keeps newest `generationsKeep` (7) and anything newer than `expiry` (7d), overridable by `NUCLEUS_GC_GENERATIONS_KEEP` / `NUCLEUS_GC_EXPIRY`. Daily `nixStoreGc` and weekly root-plus-user `gc-weekly` run on schedule.

A store lock held an hour with no CPU growth across watchdog ticks is stalled: SIGTERM then SIGKILL after `NUCLEUS_STORE_LOCK_RECLAIM_GRACE` (30 s), at most once per `NUCLEUS_STORE_LOCK_RECLAIM_COOLDOWN` (6 h), never restarting the daemon. Younger locks (`NUCLEUS_STORE_LOCK_STALL_SECONDS`, 3600) and active jobs are left alone.

Btrfs `compress-force=zstd` underreports `df`/`du`; measure with `compsize` or `btdu`. NixOS runs weekly `duperemove` over `/nix/store` via `gc.sh`; opt out with `--no-duperemove-gc`. `writeNucleusShellApplication` puts scripts and src under `$out` with shared derivations; reflinks apply to wallpaper and VM images, while `equaliser` and `camillagui-backend` must be copied. Rejected: disabling keep flags, `nix store optimise` after every rebuild, `-d` GC. Store audit: `--store-audit` or `NUCLEUS_HEALTH_CHECK_STORE_AUDIT=1`.

Details: `.agents/skills/nucleus-platform-reference/references/nix-store-space.md`.
