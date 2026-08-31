---
description: "Use when adding or modifying package manager installations, configuration, or setup scripts. Covers supply chain delay defaults enforced across all managed package managers."
name: "Supply Chain Hardening"
applyTo: "src/modules/shell*.nix, src/modules/agents.nix, src/modules/pwsh.nix, src/hosts/Windows/user/env.dsc.yml, src/platforms/Windows/modules/**/*.ps1, scripts/check.sh, scripts/check.ps1, scripts/update.sh, scripts/update.ps1, src/lockfiles/lifecycle-allowlist.json"
---

# Supply chain hardening

All managed package managers in this repository MUST have a minimum release age delay configured to limit exposure to newly published (potentially compromised) package versions.

## Active delays and pinning defaults

| Package manager | Mechanism | Setting | File(s) |
| --------------- | ---------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| **bun** | `~/.bunfig.toml` | `[install] minimumReleaseAge = 432000` (5 days in seconds), `exact = true` | `src/modules/shell.nix`, `src/platforms/Windows/modules/user/Sync-ShellProfile.ps1` |
| **uv** | `uv.toml` | `exclude-newer = "P5D"` (ISO 8601 duration) + `add-bounds = "exact"` | `src/modules/shell.nix`, `src/platforms/Windows/modules/user/Sync-ShellProfile.ps1` |

## Package managers without delay features

These lack a built-in delay mechanism and use explicit version pinning in `src/lockfiles/lockfile.json` instead:

- WinGet — no delay feature; rely on lockfile pinning
- Scoop — no delay feature; rely on lockfile pinning
- cargo-binstall — no delay feature; rely on lockfile pinning
- rustup — no delay feature; rely on lockfile pinning
- Homebrew — autoUpdate disabled globally; rely on lockfile pinning

## Lifecycle script hardening

When installing packages via `bun install -g`, the `--ignore-scripts` flag MUST be used to prevent arbitrary code execution during installation.

When installing packages via `uv tool install`, the `--no-build` flag MUST be used to require pre-built wheels. If a package lacks pre-built wheels it must be explicitly reviewed and added to the allowlist.

### Lifecycle script allowlist

`src/lockfiles/lifecycle-allowlist.json` lists packages explicitly permitted to run lifecycle scripts. Each entry maps a package name to a justification string.

Adding a package to this allowlist requires:

1. Review of what the lifecycle scripts do.
2. A documented justification in the allowlist entry.
3. Verification that the package's lifecycle scripts are necessary and cannot be replaced by a locked/deterministic alternative.

The validation scripts (`check.sh`, `check.ps1`) verify:

- The allowlist file exists and is valid JSON.
- Each entry has a non-empty justification string.

See `allow-and-deny-lists.instructions.md#D2` for the registry entry of this allowlist.

## Lockfile validation

`check.sh` and `check.ps1` run the following lockfile validations always (even in path-scoped mode):

1. **Internal consistency** — lockfile.json exists, schema is valid.
2. **Overlap detection** — no package name appears in multiple package-manager sections (except intentional multi-source packages, see `allow-and-deny-lists.instructions.md#D1`).
3. **Lifecycle allowlist validation** — see above.

With the `--online` flag (requires network), additional checks run: 4. **Freshness** — `bump-lockfile.sh --verify` queries all registries and diffs the result against the current lockfile. 5. **Yanked/removed detection** — queries registries to confirm pinned versions still exist.

## Hardening requirement for new additions

When adding a NEW package manager to this repository, you MUST:

1. Check whether it supports a minimum-release-age / exclude-newer / install-delay configuration option or environment variable.
2. If yes: configure it with `"5 days"` (or equivalent) in every shell layer — POSIX (`src/modules/shell.nix`) and Windows (`src/platforms/Windows/modules/user/Sync-ShellProfile.ps1`).
3. If no: add a note to this table explaining why, and rely on lockfile pinning.
4. If an existing package manager gains a delay feature in an upstream update, add it and remove the "no delay feature" note.
5. Check whether the package manager supports an `--ignore-scripts` equivalent or `--no-build` equivalent. If yes, configure it in `src/modules/agents.nix`.
6. If the package manager uses lifecycle scripts, add its packages to `src/lockfiles/lifecycle-allowlist.json` with justifications.
7. Ensure CI uses the locked/locked-mode equivalent for that package manager (e.g., `--frozen`, `--locked`).

## Cross-host parity

Supply chain delay settings MUST be applied on every host (macOS, NixOS, Windows) that runs the package manager. POSIX hosts share config through Nix modules; Windows has separate DSC and PowerShell profile layers — all must be kept in sync.
