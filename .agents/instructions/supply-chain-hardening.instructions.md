---
description: "Use when adding or modifying package manager installations, configuration, or setup scripts. Covers supply chain delay defaults enforced across all managed package managers."
name: "Supply Chain Hardening"
applyTo: "src/modules/shell*.nix, src/modules/agents.nix, src/modules/pwsh.nix, src/hosts/Windows/user/env.dsc.yml, src/platforms/Windows/modules/**/*.ps1, scripts/check.sh, scripts/check.ps1, scripts/update.sh, scripts/update.ps1, src/lockfiles/lifecycle-allowlist.json"
---

# Supply chain hardening

All managed package managers must have a minimum release age delay to limit exposure to compromised newly-published versions.

## Active delays and pinning defaults

| Package manager | Mechanism | Setting | File(s) |
| --------------- | ---------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| **bun** | `~/.bunfig.toml` | `[install] minimumReleaseAge = 432000` (5 days in seconds), `exact = true` | `src/modules/shell.nix`, `src/platforms/Windows/modules/user/Sync-ShellProfile.ps1` |
| **uv** | `uv.toml` | `exclude-newer = "P5D"` (ISO 8601 duration) + `add-bounds = "exact"` | `src/modules/shell.nix`, `src/platforms/Windows/modules/user/Sync-ShellProfile.ps1` |

## Package managers without delay features

WinGet, Scoop, cargo-binstall, rustup, and Homebrew lack built-in delay. Rely on version pinning in `src/lockfiles/lockfile.json`. Homebrew also disables `autoUpdate` globally.

## Lifecycle script hardening

- `bun install -g`: use `--ignore-scripts` to prevent arbitrary code execution. Packages in `lifecycle-allowlist.json` are exempted — the installer reads the allowlist and skips `--ignore-scripts` for allowlisted packages. Also pass `--linker hoisted`: the machine-wide `install.linker = "isolated"` leaves `$BUN_INSTALL/bin` unlinked for global installs (oven-sh/bun#30450), so the binary never reaches PATH.
- `uv tool install`: use `--no-build` to require pre-built wheels. Packages without pre-built wheels must be reviewed and added to the allowlist.

### Lifecycle script allowlist

`src/lockfiles/lifecycle-allowlist.json` maps package names to justification strings. To add: review lifecycle scripts, document justification, verify scripts are necessary and cannot be replaced by a locked alternative. Validation (`check.sh`, `check.ps1`): file exists, valid JSON, each entry has non-empty justification. See `allow-and-deny-lists.instructions.md#D2`.

## Lockfile validation

`check.sh` and `check.ps1` run these lockfile validations always (even in path-scoped mode):

1. **Internal consistency** — lockfile.json exists, schema is valid.
2. **Overlap detection** — no package name in multiple sections (except intentional, see `allow-and-deny-lists.instructions.md#D1`).
3. **Lifecycle allowlist validation** — see above.

With `--online` (requires network): 4. **Freshness** — `bump-lockfile.sh --verify` queries registries, diffs against current. 5. **Yanked/removed detection** — confirms pinned versions still exist.

## Adding a new package manager

1. Check for delay support (`minimum-release-age`, `exclude-newer`, install-delay env var). If yes: configure `"5 days"` in `src/modules/shell.nix` and `src/platforms/Windows/modules/user/Sync-ShellProfile.ps1`. If no: add note to table, rely on lockfile pinning.
2. Check for `--ignore-scripts` or `--no-build` equivalent. If yes: configure in `src/modules/agents.nix`.
3. If lifecycle scripts needed: add to `src/lockfiles/lifecycle-allowlist.json` with justifications.
4. Ensure CI uses locked mode (`--frozen`, `--locked`).
5. If upstream adds delay feature to existing manager: add it, remove the "no delay feature" note.

## Cross-host parity

Delay settings apply on every host. POSIX shares via Nix modules; Windows uses separate DSC and PowerShell layers. Keep in sync.
