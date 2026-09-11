---
description: "Use when editing src/lockfiles/lockfile.json, the lockfile enforcement lib (used by bump-lockfile verify), or bump-lockfile. Covers the two-tier (pinned vs suggestions) model, the warn-only→suggestions invariant, the no-cross-lockfile-duplication policy, and canonical section classification."
name: "Lockfile Enforcement"
applyTo: "src/lockfiles/lockfile.json, src/lockfiles/lockfile.schema.json, src/scripts/checks/check-steps/05-lockfile-validation.*, src/scripts/checks/lockfile-enforcement-lib.*, src/platforms/Windows/modules/user/Sync-Superpowers.ps1, src/platforms/Windows/modules/user/Sync-OpenCodeConfig.ps1, scripts/bump-lockfile.*"
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

Homebrew has no native lockfile — pins live under `homebrew`; activation runs `brew bundle --force` from nix-darwin's Brewfile.

Update with `scripts/update.sh` / `scripts/update.ps1`. For Nix packages, run `nix flake lock` from `src/`. The `uv` updater skips `.uv[<pkg>]` entries whose value is an object (VCS-pinned packages); the `bun` and `pi` updaters query the npm registry and skip object-shaped (VCS/rev) pins.

## Two-tier model

- **Pinned root** — authoritative. Enforcement lib (`lockfile-enforcement-lib.*`) compares installed versions against pins, reports drift. Pinned: `bun`, `cargo-binstall`, `cursor` (editor plugins, filesystem-based enforcement including `superpowers` via a pinned checkout), `pi`, `pwsh`, `rustup`, `scoop`, `source-builds`, `uv`, `version`, `vm-setup`, `winget`. Probes are scoped to the current host's declared packages in `src/modules/packages/desired.json`, so a Windows-only package is never reported as drift on macOS.
- **`suggestions`** — warn-only, never enforced, never causes check failure. Sub-sections: `cursor`, `homebrew` (masApps only), `ollama`, `opencode`, `vscode`, `vm-setup.windows`.

## Invariant

Section that can at most warn → `suggestions`. Unreliably verifiable (VCS/rev pins, cross-host tooling, non-authoritative data) → `suggestions`. Root: hard-fail on drift only.

## No cross-lockfile duplication

`lockfile.json` must not duplicate version/pin data from another lockfile. `flake.lock` owns nixpkgs and homebrew tap revisions. Nix modules (`homebrew.nix`, `editors.nix`, `core.nix`) listing package names are not lockfiles — that is not duplication.

Removed: `suggestions.nixpkgs`, `suggestions.homebrew.brews`/`casks`. Retained: `suggestions.homebrew.masApps` (App Store IDs are not versions).

## `suggestions.vscode` — the one intentional exception

`suggestions.vscode` is the only section permitted to duplicate `flake.lock` data. POSIX locks extensions via `flake.lock`; Windows cannot evaluate Nix (`code --install-extension` needs the concrete version). Stays under `suggestions` (warn-only, not locked on all platforms). Verify probe (`_lfe_check_vscode`) is warn-only.

## Canonical classification

- **Root (pinned):** `bun`, `uv`, `cargo-binstall`, `rustup`, `pwsh`, `scoop`, `winget`, `vm-setup`, `source-builds`/`version`, `pi`, `cursor` (editor plugins — filesystem-based enforcement including `superpowers` via a pinned checkout).
- **`suggestions` (warn-only):** `cursor` (editor extensions), `homebrew.masApps`, `ollama`, `opencode`, `vscode`, `vm-setup.windows`.

## Shared probe library

Probe logic lives in a shared lib used by `bump-lockfile --verify-installed` (and Windows equivalent). Not wired into repo check/test steps — validates the provisioned machine only. Check step `05-lockfile-validation.*` does structural validation separately, does not source the enforcement lib.

### Superpowers provisioning

`cursor.superpowers` is the single pin (source + rev); `suggestions.opencode` no longer duplicates it.

- **POSIX**: `builtins.fetchGit` in `src/modules/agents.nix` checks the rev out at Nix build time and activation symlinks `<nucleusUserRoot>/plugins/superpowers` → the store path. `_lfe_check_superpowers` verifies the symlink targets `/nix/store/`.
- **Windows**: `Sync-Superpowers.ps1` clones the pin into `%LOCALAPPDATA%\nucleus\plugins\superpowers` and checks out the rev (detached HEAD); it then links the pi extension and the opencode plugin. `Invoke-LockfileEnforcement` verifies the checkout's HEAD matches the pinned rev.
- Skill files are layered into `~/.agents/skills/` from `<plugin>/skills` (the agents-skills sync takes an extra source directory).

- POSIX: `src/scripts/checks/lockfile-enforcement-lib.sh` (`_lfe_check_*`, `verify_installed_versions`). `bump-lockfile --verify-installed` calls `verify_installed_versions`.
- Windows: `src/scripts/checks/lockfile-enforcement-lib.ps1` (`Invoke-LockfileEnforcement`). `bump-lockfile -VerifyInstalled` calls it.

Changing probe logic: edit the shared lib, re-run PSScriptAnalyzer on ps1 files. Enforcement runs only via `bump-lockfile --verify-installed` / `-VerifyInstalled`.

## bump-lockfile behavior

- `--verify` / `-Verify`: diff-based; exit 1 if lockfile would change (updaters available).
- `--verify-installed` / `-VerifyInstalled`: compares installed versions against pinned sections; exit 1 on drift; never writes. Always warns for `suggestions`.
