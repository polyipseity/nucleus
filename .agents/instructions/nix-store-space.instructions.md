---
description: "Use when changing Nix store policy, GC thresholds, script bundling, or store-space audits in nucleus. Documents rejected approaches, host filesystem limits, bundleDefault policy, and GC semantics."
name: "Nix Store Space"
applyTo: "src/modules/posix-base.nix, src/modules/configs/nix/**, src/flake.nix, src/modules/lib/script-tree.nix, scripts/gc.sh, src/scripts/cleanup-nix-build-artifacts.sh, src/scripts/services/duperemove-store.sh"
---

# Nix store space policy

## Canonical store policy

Managed in [`posix-base.nix`](../../src/modules/posix-base.nix) (NixOS `nix.settings`) and mirrored in [`nix.custom.conf`](../../src/modules/configs/nix/nix.custom.conf) on MacBook (`nix.enable = false` under Determinate Nix).

| Setting | Value | Notes |
| ------- | ----- | ----- |
| `auto-optimise-store` | `true` | Hard-link deduplication; no per-rebuild full `nix store optimise` |
| `keep-derivations` / `keep-outputs` | `true` | Intentional — supports `nix-shell` and rollback |
| `lazy-trees` | `true` | Reduces eval-time copy of flake source trees |
| `eval-cores` | `0` (`auto`) | Parallel Nix evaluation |
| `min-free` | `16 GB` | GC trigger when store volume free space drops below this during builds |
| `max-free` | `64 GB` | Target free space after automatic GC |

Different from [`apply.sh`](../../scripts/apply.sh) `health-check` `--min-free-bytes` (16 GB system-wide).

Age-based GC: `nix-collect-garbage --delete-older-than` ([`posix-base.nix`](../../src/modules/posix-base.nix), [`nix-store-gc.sh`](../../src/scripts/services/nix-store-gc.sh), [`gc.sh`](../../src/scripts/gc.sh)). Never `-d`.

**Generation retention:** newest `generationsKeep` (default 7) AND newer than `expiry` (default 7d). Config: [`gc-options.nix`](../../src/modules/lib/gc-options.nix); override: `NUCLEUS_GC_GENERATIONS_KEEP`/`NUCLEUS_GC_EXPIRY` + `nucleus-gc` flags.

**Scheduling:** daily `nixStoreGc` → `nix-store-gc.sh`; weekly `gc-weekly` → `gc.sh` (root + user via `sudo -u`) + `duperemove` on btrfs `/nix/store` ([`duperemove-store.sh`](../../src/scripts/services/duperemove-store.sh)).

**Host `/nix`:** MacBook — APFS volume (Determinate); `min-free`/`max-free` apply. NixOS — Btrfs `@nix` ([`disks.nix`](../../src/hosts/NixOS/hardware/disks.nix), [`btrfs-options.nix`](../../src/hosts/NixOS/btrfs-options.nix)), `compress-force=zstd`, `noatime`. Guest: same ([`src/vms/NixOS/formats/`](../../src/vms/NixOS/formats/)).

## Btrfs compression and measurement

- `compress-force=zstd` on `@` and `@nix` — forces on substituted paths ([nix#3550](https://github.com/NixOS/nix/issues/3550)); `df`/`du` under-report; use `compsize` or `btdu`

## `$out` layout and duplication

`writeNucleusShellApplication` ([`flake.nix`](../../src/flake.nix)): `$out/scripts` + `$out/src`, entry at `$out/<scriptName>.sh`. No `bundleDefault`. Each app symlinks shared derivations (two symlinks, no per-app tree duplication). Shellcheck in CI only. Call-site: [`nix-and-script-authoring.instructions.md`](nix-and-script-authoring.instructions.md).

## Runtime copies (reflink)

| Host | Store FS | Reflink at runtime |
| ---- | -------- | ------------------ |
| MacBook | APFS (`/nix` volume) | `copy_with_reflink` in `lib.sh` for wallpaper/VM images on CoW volume |
| NixOS | Btrfs `@nix` subvolume | `copy_with_reflink` for wallpaper/VM qcow on same btrfs partition |
| Windows | No Nix store | N/A |

D3: [`equaliser`](../../src/flake.nix) and [`camillagui-backend`](../../src/hosts/MacBook/camilladsp.nix) ship self-contained `.app` bundles — must copy, not symlink (breaks macOS app isolation and code signing). E3: [`core.nix`](../../src/modules/core.nix) registers same `pkgs.<attr>` in `environment.systemPackages` + `home.packages` — one store path, dual PATH, intentional.

## Rejected items

| ID | Item | Why rejected |
| ---- | ---- | ------------ |
| B7 | `keep-derivations` / `keep-outputs` = `false` | Breaks `nix-shell` / rollback |
| B8 | `nix store optimise` after every rebuild | Too slow; use `auto-optimise-store` + `nix.optimise.automatic` |
| C3 | `nix-collect-garbage -d` | Destructive; age-based GC exists |
| C7 | Default expiry 7d → 3d | Too aggressive; use `--nix-expiry` to opt in |
| A8 | Content-addressed script bundles | Experimental; premature |
| E3 | "Fix" dual `sharedPackages` | Intentional design |

## Active btrfs maintenance (NixOS)

| ID | Item | Policy |
| ---- | ---- | ------ |
| F2 | btrfs + `duperemove` | Weekly via `gc-weekly` → `gc.sh` → [`duperemove-store.sh`](../../src/scripts/services/duperemove-store.sh) on `/nix/store` (`--hashfile=/var/lib/duperemove/hashfile`). Opt out: `nucleus-gc --no-duperemove-gc`. |
| F4 | `@nix` subvolume + `noatime` | Provisioned on NixOS host and guest images. |

## Not applicable

| ID | Item | Why |
| ---- | ---- | --- |
| F1 | Enable APFS clones | Mac `/nix` already APFS |
| F3 | ZFS online dedup | No ZFS in repo |
| F5 | CoW FS for reflink ingestion | Upstream Nix required |
| D2-Win | VM reflink on Windows | NTFS — no APFS-style reflink |
| D4 | Windows wallpaper hardlink/reflink | NTFS; symlink sufficient |
| G1 | Reflink copy into Nix store | Not implemented upstream |
| G2 | Incremental `nix store optimise` | [nix#9450](https://github.com/NixOS/nix/issues/9450) |
| G4 | Bind-mount sandbox files | [nix#8965](https://github.com/NixOS/nix/pull/8965) |
| G5 | Derivation hardlink hints | Closed wontfix [nix#1272](https://github.com/NixOS/nix/issues/1272) |
| G6 | Content-addressed store paths | Experimental upstream CLI |
| G7 | `.flakeignore` / lazy self inputs | [nix#4097](https://github.com/NixOS/nix/issues/4097); `lazy-trees` partial mitigation |
| G9 | nix-darwin #1551 version gate | No version gating in nucleus |

## Store audit

Opt-in: `--store-audit` or `NUCLEUS_HEALTH_CHECK_STORE_AUDIT=1`. Manual: `nix run .#apply audit-store`.

Report sections: top closures via `nix path-info --json`, grouped by store path prefix; generation count; reclaim hint (→ `nucleus-gc`); GC roots by category; stale `result` symlinks; Linux-builder VM store (MacBook only).

**Note:** duplicate checkouts each pin `.direnv/flake-inputs` GC roots — consolidate or `nucleus-gc` after removing stale repos.

G8: [`linux-builder.nix`](../../src/hosts/MacBook/linux-builder.nix) — aarch64-linux builds in NixOS VM with separate `/nix/store`. Align substituters/trusted keys, `builders-use-substitutes = true`, scheduled builder-side GC.
