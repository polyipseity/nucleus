---
description: "Use when editing the lockfile, its enforcement lib, or the update lockfile action."
name: "Lockfile Enforcement"
applyTo: "src/lockfiles/lockfile.json, src/lockfiles/lockfile.schema.json, src/scripts/checks/check-steps/05-lockfile-validation.*, src/scripts/checks/lockfile-enforcement-lib.*, src/platforms/Windows/modules/user/Sync-SuperpowersPlugin.ps1, src/platforms/Windows/modules/user/Sync-OpenCodeConfig.ps1"
---

# Lockfile enforcement

`src/lockfiles/lockfile.json` pins tool versions; `lockfile.schema.json` is the authoritative field list. Every section is required and may be `{}`. Homebrew has no native lockfile or per-cask pin: taps follow `flake.lock` revisions (`mutableTaps = false`), `auto_updates` casks move on their own, and the only Homebrew data here is `suggestions.homebrew.masApps` (App Store ids are not versions).

Update with `scripts/update.sh` / `update.ps1`; Nix pins come from `nix flake lock` in `src/`. The uv updater skips `.uv[<pkg>]` object values; bun and pi skip object-shaped pins. `psgallery` recomputes the nupkg hash for object entries, warning and leaving the entry unchanged when the hash cannot be fetched.

## Two tiers

Pinned root is authoritative; enforcement compares installed versions and hard-fails on drift. `suggestions` is warn-only, never enforced, never fails a check. Anything that can only warn, plus VCS/rev pins, cross-host tooling, and non-authoritative data, belongs in `suggestions`. `cursor` is a pinned root for the superpowers checkout only; extension lists live under `suggestions.cursor` and `suggestions.vscode`. `whisper` is the only pinned root with no registry entry because it pins a data file.

No cross-lockfile duplication: `flake.lock` owns nixpkgs and Homebrew tap revisions. Nix modules naming packages are not lockfiles. `suggestions.vscode` is the intentional exception because Windows cannot evaluate Nix and `code --install-extension` needs a version; its probe `_lfe_check_vscode` is warn-only.

## PSGallery and whisper

`psgallery` is pinned from PSGallery itself: nixpkgs ships `pwsh` but none of `psini`, `pester`, `powershell-yaml`, `PSScriptAnalyzer`, `psframework`, `importexcel`, `PSResourceGet`. PSGallery has no release-age delay, so entries are a version string or `{version, hash}`; `hash` is the SRI of the SHA256 for `https://www.powershellgallery.com/api/v2/package/<Name>/<Version>`, as recorded by `nix store prefetch-file --json --hash-type sha256`. `_lfe_check_psgallery` checks installed module versions only; the extracted module cannot verify the nupkg hash, which pins the declarative fetch.

Whisper weights ship in no package manager, so entries are always `{revision, hash, url}` objects. `revision` is the upstream commit `url` resolves to and must appear in it, because HuggingFace `main` is mutable. Upgrade both fields with `nix store prefetch-file`. Both probes rehash the deployed copy under `<nucleus USER root>/models`: POSIX `_lfe_check_whisper` decodes SRI with `base64 -d | od -An -v -tx1` (the `-v` is load-bearing, or identical bytes collapse to `*`), Windows uses `Get-NucleusSriHash` in `Invoke-LockfileEnforcement`. Hashing the deployed copy is deliberate; the first Windows install of hermes-agent still needs one real run.

## Probes and superpowers

Probe logic lives in `src/scripts/checks/lockfile-enforcement-lib.sh` (`_lfe_check_*`, `verify_installed_versions`, called by `update.sh lockfile --verify-installed`) and `lockfile-enforcement-lib.ps1` (`Invoke-LockfileEnforcement`, called by `update.ps1 -Action lockfile -VerifyInstalled`). Check and test steps never source it; step 05 validates structure separately. Probes cover packages declared for the current host in `src/modules/packages/desired.json`. A `pin: "flake:<node>"` has no lockfile version and is resolved by `Resolve-NucleusFlakePin` against `src/flake.lock` and checked against uv's `direct_url.json`; `{source, rev}` pins use the same path on both hosts.

`cursor.superpowers` is the single source-plus-rev pin. POSIX `builtins.fetchGit` in `agents.nix` checks it out at build time and activation symlinks `<nucleusUserRoot>/plugins/superpowers` to the store path; `_lfe_check_superpowers` verifies the `/nix/store/` target. Windows `Sync-SuperpowersPlugin.ps1` clones it to `%LOCALAPPDATA%\nucleus\plugins\superpowers`, checks out detached, and links the pi extension and opencode plugin; `Invoke-LockfileEnforcement` verifies HEAD. Probe changes require editing the shared lib and rerunning PSScriptAnalyzer on the `.ps1` files.

`--verify` / `-Verify` exits 1 when the lockfile would change; `--verify-installed` / `-VerifyInstalled` compares installed versions, exits 1 on drift, never writes, and always warns for `suggestions`.
