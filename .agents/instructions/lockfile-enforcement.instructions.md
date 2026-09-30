---
description: "Use when editing src/lockfiles/lockfile.json, the lockfile enforcement lib (used by the update lockfile action), or that action. Covers the two-tier (pinned vs suggestions) model, the warn-only→suggestions invariant, the no-cross-lockfile-duplication policy, and canonical section classification."
name: "Lockfile Enforcement"
applyTo: "src/lockfiles/lockfile.json, src/lockfiles/lockfile.schema.json, src/scripts/checks/check-steps/05-lockfile-validation.*, src/scripts/checks/lockfile-enforcement-lib.*, src/platforms/Windows/modules/user/Sync-SuperpowersPlugin.ps1, src/platforms/Windows/modules/user/Sync-OpenCodeConfig.ps1"
---

# Lockfile enforcement

## Lockfile format

The consolidated lockfile at `src/lockfiles/lockfile.json` pins tool and package versions. All sections are required but may be empty (`{}`).

| Key | Format | Description |
| ---------------- | --------------------------------- | ---------------------------------------- |
| `scoop` | `string → string` | Scoop package → version |
| `cargo-binstall` | `string → string` | Cargo crate → version |
| `bun` | `string → string` | Bun package → version |
| `uv` | `string → string`; VCS pins `{source, rev}` | Uv package → version |
| `rustup` | `string → string` | Rust toolchain → date |
| `winget` | `string → string` | WinGet ID → version |
| `vscode` | `string → string` | VS Code extension → version |
| `homebrew` | `object with brews/casks/masApps` | Homebrew formula/cask/MAS → version |
| `ollama` | `string → string` | Ollama model → digest hash |
| `pi` | `string → string` | Pi coding agent extension → version |
| `psgallery` | `string → string`; hash pins `{version, hash}` | PowerShell module → version (PSGallery) |
| `whisper` | `object; {url, revision, hash}` | whisper.cpp ggml model file → revision + SRI hash |

Homebrew has no native lockfile — pins live under `homebrew`; activation runs `brew bundle --force` from nix-darwin's Brewfile.

Update with `scripts/update.sh` / `scripts/update.ps1`. For Nix packages, run `nix flake lock` from `src/`. The `uv` updater skips `.uv[<pkg>]` entries whose value is an object (VCS-pinned packages); the `bun` and `pi` updaters query the npm registry and skip object-shaped (VCS/rev) pins; the `psgallery` updater recomputes the nupkg hash for object-form entries and leaves the entry unchanged (with a warning) when the hash cannot be fetched.

### `psgallery` pins

`psgallery` is a pinned root whose source is PSGallery itself: nixpkgs packages none of these modules (probed against nixpkgs: `psini`, `pester`, `powershell-yaml`, `PSScriptAnalyzer`, `psframework`, `importexcel`, and `PSResourceGet` are all absent; nixpkgs ships the `pwsh` runtime only), so the lockfile is the only pin.

PSGallery has no release-age delay feature, so the mitigation is the version pin plus, for hash-pinned entries, the SHA256 of the module's nupkg. An entry is either a version string or a `{version, hash}` object; `hash` is the SRI form of the SHA256 of `https://www.powershellgallery.com/api/v2/package/<Name>/<Version>`, which is what `nix store prefetch-file --json --hash-type sha256` records.

The `psgallery` probe (`_lfe_check_psgallery`) verifies the installed module version only. The installed artifact is the extracted module directory, not the nupkg, so `hash` is not verifiable against an installation; it pins the artifact the declarative module path fetches.

### `whisper` pins

`whisper` is a pinned root for a data file rather than a program: no package manager ships the whisper.cpp ggml weights (the Scoop manifest says so in its own `notes`), so the lockfile is the only pin. Entries are always the object form, because a bare version string cannot express a content hash.

`revision` is the upstream commit the `url` resolves to, and the `url` must embed it. A HuggingFace `main` ref is mutable, so without the revision the same URL yields different bytes and the pinned hash rejects every legitimate update. Upgrading a model is a two-step change: pick the new revision, re-derive `hash` with `nix store prefetch-file`, and update both fields together.

Both probes re-hash the deployed copy under `<nucleus USER root>/models` and compare against `hash`: `_lfe_check_whisper` on POSIX (which decodes the SRI to hex with `base64 -d | od -An -v -tx1`, the `-v` being load-bearing — without it `od` collapses a run of identical bytes to `*` and a hash of all zeros would silently compare as a prefix), and the `whisper` block in `Invoke-LockfileEnforcement` on Windows (which compares SRI directly via `Get-NucleusSriHash`). Hashing the deployed copy rather than trusting the fetch is deliberate: on Windows nothing else verifies a 141 MB download, and on POSIX the store path is verified at build time while the copy `whisper-cli` actually opens is an ordinary file.

## Two-tier model

- **Pinned root** — authoritative. Enforcement lib (`lockfile-enforcement-lib.*`) compares installed versions against pins, reports drift. Pinned: `bun`, `cargo-binstall`, `cursor` (editor plugins, filesystem-based enforcement including `superpowers` via a pinned checkout), `pi`, `psgallery`, `rustup`, `scoop`, `source-builds`, `uv`, `version`, `vm-setup`, `whisper`, `winget`. Probes are scoped to the current host's declared packages in `src/modules/packages/desired.json`, so a Windows-only package is never reported as drift on macOS. `whisper` is the one pinned root with no corresponding registry entry: it pins a data file, and its probe is keyed on the lockfile section alone.
- **`suggestions`** — warn-only, never enforced, never causes check failure. Sub-sections: `cursor`, `homebrew` (masApps only), `ollama`, `opencode`, `vscode`, `vm-setup.windows`.

## Invariant

Section that can at most warn → `suggestions`. Unreliably verifiable (VCS/rev pins, cross-host tooling, non-authoritative data) → `suggestions`. Root: hard-fail on drift only.

## No cross-lockfile duplication

`lockfile.json` must not duplicate version/pin data from another lockfile. `flake.lock` owns nixpkgs and homebrew tap revisions. Nix modules (`homebrew.nix`, `editors.nix`, `core.nix`) listing package names are not lockfiles — that is not duplication.

Removed: `suggestions.nixpkgs`, `suggestions.homebrew.brews`/`casks`. Retained: `suggestions.homebrew.masApps` (App Store IDs are not versions).

## `suggestions.vscode` — the one intentional exception

`suggestions.vscode` is the only section permitted to duplicate `flake.lock` data. POSIX locks extensions via `flake.lock`; Windows cannot evaluate Nix (`code --install-extension` needs the concrete version). Stays under `suggestions` (warn-only, not locked on all platforms). Verify probe (`_lfe_check_vscode`) is warn-only.

## Canonical classification

- **Root (pinned):** `bun`, `uv`, `cargo-binstall`, `rustup`, `psgallery`, `scoop`, `whisper`, `winget`, `vm-setup`, `source-builds`/`version`, `pi`, `cursor` (editor plugins — filesystem-based enforcement including `superpowers` via a pinned checkout).
- **`suggestions` (warn-only):** `cursor` (editor extensions), `homebrew.masApps`, `ollama`, `opencode`, `vscode`, `vm-setup.windows`.

## Shared probe library

Probe logic lives in a shared lib used by `update.sh lockfile --verify-installed` (and Windows equivalent). Not wired into repo check/test steps — validates the provisioned machine only. Check step `05-lockfile-validation.*` does structural validation separately, does not source the enforcement lib.

Probes are scoped: only packages the current host declares in `src/modules/packages/desired.json` are checked, so a pin kept for another host (or a lockfile entry no host declares) is never reported as drift. A tool declared with `pin: "flake:<node>"` has no lockfile version at all, so it is verified by revision instead: `Resolve-NucleusFlakePin` (shared with `Invoke-UvSetup`) resolves the node from `src/flake.lock`, and the probe compares that revision with the commit uv recorded for the install (PEP 610 `direct_url.json`). Object-shaped (`{source, rev}`) lockfile pins are verified the same way on both hosts.

What this cannot prove: the probes observe an already-provisioned machine, so a first Windows install of a flake-pinned tool (hermes-agent from the flake revision) still needs one real Windows run; the derivation and the drift report are covered by fixtures.

### Superpowers provisioning

`cursor.superpowers` is the single pin (source + rev); `suggestions.opencode` no longer duplicates it.

- **POSIX**: `builtins.fetchGit` in `src/modules/agents.nix` checks the rev out at Nix build time and activation symlinks `<nucleusUserRoot>/plugins/superpowers` → the store path. `_lfe_check_superpowers` verifies the symlink targets `/nix/store/`.
- **Windows**: `Sync-SuperpowersPlugin.ps1` clones the pin into `%LOCALAPPDATA%\nucleus\plugins\superpowers` and checks out the rev (detached HEAD); it then links the pi extension and the opencode plugin. `Invoke-LockfileEnforcement` verifies the checkout's HEAD matches the pinned rev.
- Skill files are layered into `~/.agents/skills/` from `<plugin>/skills` (the agents-skills sync takes an extra source directory).

- POSIX: `src/scripts/checks/lockfile-enforcement-lib.sh` (`_lfe_check_*`, `verify_installed_versions`). `update.sh lockfile --verify-installed` calls `verify_installed_versions`.
- Windows: `src/scripts/checks/lockfile-enforcement-lib.ps1` (`Invoke-LockfileEnforcement`). `update.ps1 -Action lockfile -VerifyInstalled` calls it.

Changing probe logic: edit the shared lib, re-run PSScriptAnalyzer on ps1 files. Enforcement runs only via `update.sh lockfile --verify-installed` / `-VerifyInstalled`.

## update lockfile behavior

- `--verify` / `-Verify`: diff-based; exit 1 if lockfile would change (updaters available).
- `--verify-installed` / `-VerifyInstalled`: compares installed versions against pinned sections; exit 1 on drift; never writes. Always warns for `suggestions`.
