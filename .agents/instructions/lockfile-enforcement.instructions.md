---
description: "Use when editing src/lockfiles/lockfile.json, the lockfile enforcement check step, or bump-lockfile. Covers the two-tier (pinned vs suggestions) model, the warn-only→suggestions invariant, and canonical section classification."
name: "Lockfile Enforcement"
applyTo: "src/lockfiles/lockfile.json, src/lockfiles/lockfile.schema.json, src/scripts/checks/check-steps/16-lockfile-enforcement.*, src/scripts/checks/lockfile-enforcement-lib.*, scripts/bump-lockfile.*"
---

# Lockfile enforcement

`src/lockfiles/lockfile.json` (schema `version: 2`) pins tool versions. Sections split into two tiers.

## Two-tier model

- **Pinned root sections** — authoritative. The check step (`16-lockfile-enforcement.*`) fails the run on any version drift. `bump-lockfile --verify` / `--verify-installed` reports drift. Currently pinned: `bun`, `cargo-binstall`, `pwsh`, `rustup`, `scoop`, `source-builds`, `uv`, `version`, `vm-setup`, `winget`.
- **`suggestions` block** — warn-only, never enforced. Always emits a warning that each sub-section is non-authoritative. Never causes a check failure. Sub-sections: `homebrew`, `nixpkgs`, `ollama`, `vscode`, `vm-setup`.

## Invariant

Any section that is enforceable at most warn-only MUST live under `suggestions`, never as a pinned root child. If a section cannot be reliably version-verified (VCS/rev pins, cross-host tooling, or non-authoritative audit data), it belongs in `suggestions` — not as a root key. This keeps the root reserved for sections that hard-fail on drift.

## Canonical classification

- **Root (pinned, enforced):** tools with a deterministic installed-version query on the target platform (`bun` global packages, `uv` tools, `cargo-binstall` crates, `rustup` stable toolchain, `pwsh` modules, `scoop`, `winget`, `vm-setup` ISO/digest sources, `source-builds`/`version` manual pins).
- **`suggestions` (warn-only):** `homebrew` (macOS-only, not version-verifiable from a POSIX check), `nixpkgs` (tracked by `flake.lock`), `ollama` (daemon-dependent), `vscode` (editor extensions), `vm-setup.windows` (manual digest).

## Shared probe library

Both the check step and `bump-lockfile` source the same probe logic so behavior stays identical:

- POSIX: `src/scripts/checks/lockfile-enforcement-lib.sh` (`_lfe_check_*`, `_lfe_warn_suggestions`, `_lfe_run_core`, `verify_installed_versions`). The step keeps only `run_lockfile_enforcement` (needs `check-lib.sh` skip/step helpers); `bump-lockfile --verify-installed` calls `verify_installed_versions` directly.
- Windows: `src/scripts/checks/lockfile-enforcement-lib.ps1` (`Invoke-LockfileEnforcement` with message-function delegates). The step and `bump-lockfile -VerifyInstalled` both call it.

When changing probe logic, edit the shared lib and re-run `tests/scripts/lockfile-enforcement-tests.sh` plus PSScriptAnalyzer on the ps1 files.

## bump-lockfile behavior

- `--verify` / `-Verify`: diff-based; exit 1 if the lockfile would change (updaters available).
- `--verify-installed` / `-VerifyInstalled`: compares installed tool versions against pinned sections; exit 1 on drift; never writes. Always warns for `suggestions`.
