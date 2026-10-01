---
description: "Use when editing src/lockfiles/lockfile.json, the lockfile enforcement lib (used by the update lockfile action), or that action. Covers the two-tier (pinned vs suggestions) model, the warn-only→suggestions invariant, the no-cross-lockfile-duplication policy, and canonical section classification."
name: "Lockfile Enforcement"
applyTo: "src/lockfiles/lockfile.json, src/lockfiles/lockfile.schema.json, src/scripts/checks/check-steps/05-lockfile-validation.*, src/scripts/checks/lockfile-enforcement-lib.*, src/platforms/Windows/modules/user/Sync-SuperpowersPlugin.ps1, src/platforms/Windows/modules/user/Sync-OpenCodeConfig.ps1"
---

# Lockfile enforcement

## Lockfile format

`src/lockfiles/lockfile.json` pins tool and package versions. `src/lockfiles/lockfile.schema.json` is the authoritative field list, so read it instead of trusting any table of sections. Every section is required but may be empty (`{}`). Homebrew has no native lockfile, so its pins live here and activation runs `brew bundle --force` from the nix-darwin Brewfile.

Update with `scripts/update.sh` / `scripts/update.ps1`. Nix packages are pinned by `nix flake lock` from `src/`, not here. The `uv` updater skips `.uv[<pkg>]` entries whose value is an object, and the `bun` and `pi` updaters skip object-shaped pins the same way. The `psgallery` updater recomputes the nupkg hash for object-form entries and leaves the entry unchanged with a warning when the hash cannot be fetched.

## Two-tier model

- **Pinned root**: authoritative. The enforcement lib compares installed versions against pins and reports drift. Hard-fail on drift only.
- **`suggestions`**: warn-only, never enforced, never fails a check.

A section that can at most warn belongs under `suggestions`, and so does anything unreliably verifiable (VCS/rev pins, cross-host tooling, non-authoritative data). That is the invariant; the section split follows from it.

`cursor` is a pinned root for the superpowers checkout only; the editor extension lists live under `suggestions.cursor` and `suggestions.vscode`. `whisper` is the one pinned root with no registry entry: it pins a data file, and its probe keys on the lockfile section alone.

## No cross-lockfile duplication

`lockfile.json` must not duplicate data another lockfile owns. `flake.lock` owns the nixpkgs and homebrew tap revisions. Nix modules (`homebrew.nix`, `editors.nix`, `core.nix`) that list package names are not lockfiles, so naming a package there is not duplication.

`suggestions.homebrew.masApps` stays: App Store IDs are not versions.

`suggestions.vscode` is the one intentional exception to the duplication rule. POSIX locks extensions through `flake.lock`; Windows cannot evaluate Nix, and `code --install-extension` needs a concrete version. Its probe (`_lfe_check_vscode`) is warn-only.

## `psgallery` pins

`psgallery` is a pinned root whose source is PSGallery itself: nixpkgs ships the `pwsh` runtime and none of these modules (`psini`, `pester`, `powershell-yaml`, `PSScriptAnalyzer`, `psframework`, `importexcel`, `PSResourceGet`), so the lockfile is the only pin. PSGallery has no release-age delay, so the mitigation is the version pin plus the nupkg SHA256. An entry is a version string or a `{version, hash}` object; `hash` is the SRI form of the SHA256 of `https://www.powershellgallery.com/api/v2/package/<Name>/<Version>`, which is what `nix store prefetch-file --json --hash-type sha256` records.

The probe (`_lfe_check_psgallery`) checks the installed module version only. The installed artifact is the extracted module directory, not the nupkg, so `hash` cannot be verified against an installation; it pins the artifact the declarative module path fetches.

## `whisper` pins

No package manager ships the whisper.cpp ggml weights, so the lockfile is the only pin. Entries are always object form, because a version string cannot express a content hash. `revision` is the upstream commit `url` resolves to and has to be embedded in it: a HuggingFace `main` ref is mutable, so without the revision the same URL yields different bytes and the pinned hash rejects every legitimate update. Upgrading is two fields at once: pick the revision, re-derive `hash` with `nix store prefetch-file`, update both.

Both probes re-hash the deployed copy under `<nucleus USER root>/models` and compare against `hash`. `_lfe_check_whisper` on POSIX decodes the SRI to hex with `base64 -d | od -An -v -tx1`, where `-v` is load-bearing: without it `od` collapses a run of identical bytes to `*` and an all-zero hash compares as a prefix. The `whisper` block in `Invoke-LockfileEnforcement` on Windows compares SRI through `Get-NucleusSriHash`. Hashing the deployed copy is deliberate: nothing else verifies a 141 MB download on Windows, and the copy `whisper-cli` opens is an ordinary file, not the verified store path.

## Probes

Probe logic lives in a shared lib that only the update action runs. Repo check and test steps never source it; step `05-lockfile-validation.*` does structural validation separately. POSIX: `src/scripts/checks/lockfile-enforcement-lib.sh` (`_lfe_check_*`, `verify_installed_versions`), called by `update.sh lockfile --verify-installed`. Windows: `src/scripts/checks/lockfile-enforcement-lib.ps1` (`Invoke-LockfileEnforcement`), called by `update.ps1 -Action lockfile -VerifyInstalled`.

Probes are scoped to the packages the current host declares in `src/modules/packages/desired.json`, so a pin kept for another host is never reported as drift. A tool declared `pin: "flake:<node>"` has no lockfile version and is verified by revision instead: `Resolve-NucleusFlakePin` (shared with `Invoke-UvSetup`) resolves the node from `src/flake.lock` and the probe compares it with the commit uv recorded in `direct_url.json`. Object-shaped `{source, rev}` pins are verified the same way on both hosts.

What this cannot prove: the probes observe an already-provisioned machine, so the first Windows install of a flake-pinned tool (hermes-agent) still needs one real Windows run.

## Superpowers provisioning

`cursor.superpowers` is the single pin, source plus rev.

- POSIX: `builtins.fetchGit` in `src/modules/agents.nix` checks the rev out at Nix build time and activation symlinks `<nucleusUserRoot>/plugins/superpowers` to the store path. `_lfe_check_superpowers` verifies the symlink targets `/nix/store/`.
- Windows: `Sync-SuperpowersPlugin.ps1` clones the pin into `%LOCALAPPDATA%\nucleus\plugins\superpowers` and checks out the rev detached, then links the pi extension and the opencode plugin. `Invoke-LockfileEnforcement` verifies HEAD matches the pin.

Changing probe logic means editing the shared lib and re-running PSScriptAnalyzer on the ps1 files.

## update lockfile behavior

- `--verify` / `-Verify`: diff-based, exits 1 when the lockfile would change.
- `--verify-installed` / `-VerifyInstalled`: compares installed versions against pinned sections, exits 1 on drift, never writes, always warns for `suggestions`.
