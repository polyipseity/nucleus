---
description: "Use when changing Nix store policy, GC thresholds, script bundling, or store-space audits in nucleus. Documents rejected approaches, host filesystem limits, bundleDefault policy, and GC semantics."
name: "Nix Store Space"
applyTo: "src/modules/posix-base.nix, src/modules/configs/nix/**, src/flake.nix, src/modules/lib/script-tree.nix, scripts/gc.sh, scripts/cleanup-nix.sh, src/scripts/cleanup-nix-build-artifacts.sh"
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
| `min-free` | `40 GiB` | GC trigger when store volume free space drops below this during builds |
| `max-free` | `96 GiB` | Target free space after automatic GC (512 GB–first sizing; fine on 1–2 TB) |

**Not the same as** [`health-check.sh`](../../scripts/health-check.sh) `--min-free-bytes` (default 10 GB system-wide disk warning).

Age-based store GC is canonical: `nix-collect-garbage --delete-older-than` via [`posix-base.nix`](../../src/modules/posix-base.nix), [`nix-store-gc.sh`](../../src/scripts/services/nix-store-gc.sh), and [`gc.sh`](../../scripts/gc.sh). Never use `nix-collect-garbage -d`.

**Generation retention (intersection):** system and Home Manager profile generations are pruned with the same helper ([`expire-profile-generations.sh`](../../src/scripts/lib/expire-profile-generations.sh)): keep only generations that are **both** among the newest `generationsKeep` (default **7**) **and** newer than `expiry` (default **7d**). Configured in [`gc-options.nix`](../../src/modules/lib/gc-options.nix); overridden via `NUCLEUS_GC_GENERATIONS_KEEP` / `NUCLEUS_GC_EXPIRY` and matching `nucleus-gc` flags.

**Scheduling:** daily `nixStoreGc` (system daemon / NixOS timer) runs `nix-store-gc.sh`; weekly `gc-weekly` runs full `gc.sh` as **root** with user homedir steps via `sudo -u $NUCLEUS_USERNAME`. There is no user-scope `gc-weekly` on macOS or NixOS.

MacBook `/nix` lives on a dedicated APFS volume (Determinate installer). `min-free` / `max-free` apply to that volume's free space.

## `bundleDefault` policy

`writeNucleusShellApplication` in [`flake.nix`](../../src/flake.nix) defaults to **`bundleDefault = false`**. Pass **`bundleDefault = true`** only at call sites that require the full `scripts-bundle` + `script-tree` layout.

| `bundleDefault` | Behavior |
| --------------- | -------- |
| `false` (default) | Thin wrapper with a single-script symlink plus `script-tree/src` at `$out/src` for `lib.sh` resolution |
| `true` (explicit opt-in) | Symlink full shared `scripts-bundle` + `script-tree` — required when runtime needs sibling scripts under `scripts/` (e.g. `mkCheckPwshPackage`) |

The `nucleusApp` helper does **not** override this default — each call site opts in explicitly when needed.

See [`nix-authoring.instructions.md`](nix-authoring.instructions.md) for call-site guidance.

Shellcheck runs in CI (`nucleus-check-sh` / `script-tree.nix`), not per-app derivation builds.

## Dominant duplication (mitigated)

Each `writeNucleusShellApplication` with `bundleDefault = true` previously `cp -r` the full `scripts/` and `src/scripts/` trees. Shared derivations (`nucleus-script-tree`, `nucleus-scripts-bundle`) are symlinked into app `$out` to deduplicate store bytes.

## Runtime copies (reflink)

| Host | Store FS | Reflink at runtime |
| ---- | -------- | ------------------ |
| MacBook | APFS (`/nix` volume) | Yes — `copy_with_reflink` in `lib.sh` for wallpaper and VM images when source and dest share a CoW volume |
| NixOS | ext4 on `/` | No reflink into store; VM golden→base may use reflink only on CoW-capable Linux hosts |
| Windows | No Nix store | N/A |

**D3 — Automator / `.app` bundles must copy:** [`equaliser`](../../src/flake.nix) (`stdenv.mkDerivation` copies `*.app` from the DMG into `$out/Applications/`) and [`camillagui-backend`](../../src/hosts/MacBook/camilladsp.nix) ship self-contained `.app` bundles. Symlinking store paths into bundles breaks macOS app isolation and code signing expectations — accept the store/runtime copy cost.

## E3: `sharedPackages` in system + home profiles

**Not a store bug.** [`core.nix`](../../src/modules/core.nix) registers the same `pkgs.<attr>` in `environment.systemPackages` and `home.packages`. One store path, dual PATH registration — intentional.

## Rejected items (do not implement)

| ID | Item | Why rejected |
| ---- | ---- | ------------ |
| B7 | `keep-derivations` / `keep-outputs` = `false` | Breaks `nix-shell` / rollback |
| B8 | `nix store optimise` after every rebuild | Too slow; use `auto-optimise-store` + `nix.optimise.automatic` |
| C3 | `nix-collect-garbage -d` | Destructive; age-based GC already exists |
| C7 | Default expiry 7d → 3d | Too aggressive; use `--nix-expiry` to opt in |
| A8 | Content-addressed script bundles | Experimental; premature |
| E3 | "Fix" dual `sharedPackages` | Investigated — intentional design |

## Not applicable to nucleus provisioning

### Filesystem / store stack

| ID | Item | Why not applicable |
| ---- | ---- | ------------------ |
| F1 | "Enable APFS clones" as repo action | Mac `/nix` already APFS via installer |
| F2 | btrfs + `duperemove` | No btrfs in repo; NixOS uses ext4 |
| F3 | ZFS online dedup | No ZFS in repo |
| F4 | Separate `/nix` partition + `noatime` | Not provisioned |
| F5 | CoW FS for Nix store reflink ingestion | Requires upstream Nix support (not shipped) |

### Upstream-only

| ID | Item | Why not applicable |
| ---- | ---- | ------------------ |
| G1 | Reflink copy into Nix store | Upstream not implemented |
| G2 | Incremental `nix store optimise` | Upstream [nix#9450](https://github.com/NixOS/nix/issues/9450) |
| G4 | Bind-mount sandbox files | Upstream [nix#8965](https://github.com/NixOS/nix/pull/8965) |
| G5 | Derivation hardlink hints | Closed wontfix [nix#1272](https://github.com/NixOS/nix/issues/1272) |
| G6 | Content-addressed store paths | Experimental upstream CLI |
| G7 | `.flakeignore` / lazy self inputs | Upstream [nix#4097](https://github.com/NixOS/nix/issues/4097); partial mitigation is `lazy-trees` |
| G9 | nix-darwin #1551 version gate | No version gating in nucleus |

### Runtime copy limits

| ID | Item | Why not applicable |
| ---- | ---- | ------------------ |
| D1-NixOS | Wallpaper reflink on NixOS | ext4 — no reflink |
| D2-Win | VM reflink on Windows | NTFS — no APFS-style reflink |
| D4 | Windows wallpaper hardlink/reflink | NTFS; symlink path sufficient |

## Store audit helpers

`nucleus-health-check` and `nucleus-apply` run the store audit only when opted in: `--store-audit` or `NUCLEUS_HEALTH_CHECK_STORE_AUDIT=1`.

Manual entry points: `nix run .#audit-store`, `nucleus-audit-store`, [`scripts/audit-store.sh`](../../scripts/audit-store.sh) (sources [`audit-store.sh`](../../src/scripts/lib/audit-store.sh)).

Report sections:

- `nix path-info --json-format 1 --json --all --closure-size` top closures (via jq)
- Grouped closure totals by store path prefix (darwin-system, home-manager-generation, …)
- System generation count (`nix-env --list-generations` / privileged `darwin-rebuild --list-generations`)
- Generation reclaim hint (intersection of `generationsKeep` + `expiry`; points to `nucleus-gc`)
- GC roots bucketed by category (`direnv`, `home-manager`, `nix-profile`, `flake-registry`, `other`)
- Stale `result` symlinks (repo scan)
- Linux-builder VM store size (MacBook only; starts VM via launchd when needed)

**Operational note:** duplicate nucleus checkouts (e.g. iCloud + `~/dev/...`) each pin `.direnv/flake-inputs` GC roots — consolidate checkouts or run `nucleus-gc` after removing stale repos to reclaim store space.

## Linux builder (G8)

[`linux-builder.nix`](../../src/hosts/MacBook/linux-builder.nix) runs aarch64-linux builds in a NixOS VM with a separate `/nix/store`. Mitigation: align substituters/trusted keys with host, `builders-use-substitutes = true`, and scheduled builder-side GC.
