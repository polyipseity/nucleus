---
description: "Use when editing src/lockfiles/lockfile.json, the lockfile enforcement lib (used by bump-lockfile verify), or bump-lockfile. Covers the two-tier (pinned vs suggestions) model, the warn-only→suggestions invariant, the no-cross-lockfile-duplication policy, and canonical section classification."
name: "Lockfile Enforcement"
applyTo: "src/lockfiles/lockfile.json, src/lockfiles/lockfile.schema.json, src/scripts/checks/check-steps/05-lockfile-validation.*, src/scripts/checks/lockfile-enforcement-lib.*, scripts/bump-lockfile.*"
---

# Lockfile enforcement

`src/lockfiles/lockfile.json` (schema `version: 2`) pins tool versions. Sections split into two tiers.

## Two-tier model

- **Pinned root sections** — authoritative. The enforcement lib (`lockfile-enforcement-lib.*`, used by `bump-lockfile --verify-installed` / `-VerifyInstalled`) compares installed versions against pins and reports drift. Currently pinned: `bun`, `cargo-binstall`, `cursor` (editor plugins — filesystem-based enforcement), `pwsh`, `rustup`, `scoop`, `source-builds`, `uv`, `version`, `vm-setup`, `vscode` (editor plugins — filesystem-based enforcement), `winget`.
- **`suggestions` block** — warn-only, never enforced. Always warns that sub-sections are non-authoritative. Never causes a check failure. Sub-sections: `cursor`, `homebrew` (masApps only), `ollama`, `opencode`, `vscode`, `vm-setup.windows`.

## Invariant

Any section that can at most warn must live under `suggestions`, not as a pinned root child. If a section cannot be reliably version-verified (VCS/rev pins, cross-host tooling, non-authoritative audit data), it belongs in `suggestions`. Root is reserved for sections that hard-fail on drift.

## No cross-lockfile duplication

`lockfile.json` MUST NOT duplicate version/pin information that already lives in another **LOCKFILE**. `flake.lock` is the authoritative source for nixpkgs revisions and homebrew tap revisions; any section whose data is fully derivable from another lockfile MUST NOT be added to `lockfile.json`.

Nix modules (`homebrew.nix`, `editors.nix`, `core.nix`) are NOT lockfiles — listing package names there does not count as lockfile duplication. The duplication that matters is version/tap data that already lives in a lockfile (`flake.lock`).

Removed duplicates (per this policy): `suggestions.nixpkgs` (nixpkgs revisions live in `flake.lock`), `suggestions.homebrew.brews`/`suggestions.homebrew.casks` (tap revisions live in `flake.lock`). `suggestions.homebrew.masApps` is retained because an App Store ID is not a version and is not in any lockfile.

## `suggestions.vscode` — the one intentional exception

`suggestions.vscode` is the ONLY section permitted to duplicate `flake.lock` data, because:

- VS Code extension versions are locked by `flake.lock` on POSIX (nix derivations via `nixpkgs` + `nix-vscode-extensions`), but the Windows provisioning path is pure PowerShell (`code --install-extension <id>@<version>`) and cannot evaluate Nix to resolve the version — it needs the concrete version string from `lockfile.json`.
- Therefore `suggestions.vscode` MUST stay in `lockfile.json` as the Windows lock bridge, even though it duplicates `flake.lock` on POSIX.
- It remains under `suggestions` (warn-only) because it is not actually locked on all platforms (POSIX is locked by `flake.lock`, not `lockfile.json`). The cross-platform verify probe (`_lfe_check_vscode` / the `Invoke-LockfileEnforcement` vscode block) is warn-only.

All other `flake.lock` duplicates (nixpkgs, homebrew brews/casks) are removed.

## Canonical classification

- **Root (pinned, enforced):** tools with a deterministic installed-version query on the target platform (`bun` global packages, `uv` tools, `cargo-binstall` crates, `rustup` stable toolchain, `pwsh` modules, `scoop`, `winget`, `vm-setup` ISO/digest sources, `source-builds`/`version` manual pins, `cursor`/`vscode` editor plugins — filesystem-based enforcement).
- **`suggestions` (warn-only):** `cursor` (editor extensions, same as `vscode`), `homebrew.masApps` (App Store IDs, not in any lockfile), `ollama` (daemon-dependent), `opencode` (VCS-pinned plugins, no installed-version query), `vscode` (editor extensions — Windows lock bridge, see above), `vm-setup.windows` (manual digest).

## Shared probe library

The enforcement probe logic lives in a shared lib used by `bump-lockfile --verify-installed` (and the Windows equivalent). It is NOT wired into any repo check/test step — enforcement validates the provisioned machine only. The check step `05-lockfile-validation.*` performs structural validation (placeholder/overlap checks) separately and does NOT source the enforcement lib.

- POSIX: `src/scripts/checks/lockfile-enforcement-lib.sh` (`_lfe_check_*`, `_lfe_check_vscode`, `_lfe_warn_suggestions`, `_lfe_run_core`, `verify_installed_versions`). `bump-lockfile --verify-installed` calls `verify_installed_versions` directly.
- Windows: `src/scripts/checks/lockfile-enforcement-lib.ps1` (`Invoke-LockfileEnforcement` with message-function delegates). `bump-lockfile -VerifyInstalled` calls it.

When changing probe logic, edit the shared lib and re-run PSScriptAnalyzer on the ps1 files. Enforcement is NOT a repo check/test step — it runs only via `bump-lockfile --verify-installed` / `-VerifyInstalled` against the provisioned machine.

## bump-lockfile behavior

- `--verify` / `-Verify`: diff-based; exit 1 if the lockfile would change (updaters available).
- `--verify-installed` / `-VerifyInstalled`: compares installed tool versions against pinned sections; exit 1 on drift; never writes. Always warns for `suggestions`.
