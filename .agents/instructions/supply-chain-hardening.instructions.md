---
description: "Use when adding or modifying package manager installations, configuration, or setup scripts. Covers supply chain delay defaults enforced across all managed package managers."
name: "Supply Chain Hardening"
applyTo: "src/modules/shell*.nix, src/modules/agents.nix, src/modules/pwsh.nix, src/hosts/Windows/user/env.dsc.yml, src/hosts/Windows/modules/**/*.ps1, scripts/check.sh, scripts/check.ps1, scripts/bump-lockfile.sh, scripts/bump-lockfile.ps1, src/lockfiles/lifecycle-allowlist.json"
---

# Supply Chain Hardening

All managed package managers in this repository MUST have a minimum release age
delay configured to limit exposure to newly published (potentially compromised)
package versions.

## Active delays and pinning defaults

| Package manager | Mechanism | Setting | File(s) |
|---|---|---|---|
| **bun** | `~/.bunfig.toml` | `[install] minimumReleaseAge = 432000` (5 days in seconds), `saveExact = true` | `src/modules/shell.nix` |
| **uv** | `UV_EXCLUDE_NEWER` env var + `uv.toml` | `"P5D"` (ISO 8601 duration) + `add-bounds = "exact"` | `src/modules/shell/env.nix`, `src/modules/shell.nix`, `src/hosts/Windows/user/env.dsc.yml`, `src/hosts/Windows/modules/user/Sync-ShellProfile.ps1` |

## Package managers without delay features

These are used but lack a built-in delay mechanism. They are managed through
explicit version pinning in `src/lockfiles/lockfile.json` instead:

- WinGet — no delay feature; rely on lockfile pinning
- Scoop — no delay feature; rely on lockfile pinning
- cargo-binstall — no delay feature; rely on lockfile pinning
- rustup — no delay feature; rely on lockfile pinning
- Homebrew — autoUpdate disabled globally; rely on lockfile pinning

## Lifecycle script hardening

When installing packages via `bun install -g`, the `--ignore-scripts` flag MUST
be used to prevent arbitrary code execution during installation.

When installing packages via `uv tool install`, the `--no-build` flag MUST be
used to require pre-built wheels. If a package lacks pre-built wheels it must
be explicitly reviewed and added to the allowlist.

### Lifecycle script allowlist

`src/lockfiles/lifecycle-allowlist.json` contains the list of packages that are
explicitly permitted to run lifecycle scripts. Each entry maps a package name
to a justification string explaining why lifecycle scripts are acceptable.

Adding a package to this allowlist requires:
1. Review of what the lifecycle scripts do.
2. A documented justification in the allowlist entry.
3. Verification that the package's lifecycle scripts are necessary and cannot
   be replaced by a locked/deterministic alternative.

The validation scripts (`check.sh`, `check.ps1`) verify:
- The allowlist file exists and is valid JSON.
- Each entry has a non-empty justification string.
- (Future) Packages known to have lifecycle scripts without an allowlist entry
  are flagged.

## Lockfile validation and --verify mode

`check.sh` and `check.ps1` run the following lockfile validations always
(even in path-scoped mode):

1. **Internal consistency** — lockfile.json exists, schema is valid.
2. **Overlap detection** — no package name appears in multiple package-manager
   sections (except intentional multi-source packages).
3. **Lifecycle allowlist validation** — see above.

With the `--verify` flag (requires network), additional checks run:
4. **Freshness** — `bump-lockfile.sh --verify` queries all registries and diffs
   the result against the current lockfile. Exits non-zero if stale.
5. **Yanked/removed detection** — queries registries to confirm pinned versions
   still exist.

`bump-lockfile.sh` and `bump-lockfile.ps1` accept a `--verify` flag that runs
all registry queries without writing to disk, then diffs against the current
lockfile.

## CI drift detection

`.github/workflows/drift-detect.yml` runs weekly (Sunday 06:00 UTC) on
ubuntu-latest and macos-latest:
- `bump-lockfile --verify` — checks if any pinned version is stale.
- `check --verify` — runs all online determinism checks.

This workflow is separate from `ci.yml` because `--verify` requires network
access and non-deterministic registry calls.

## Hardening requirement for new additions

When adding a NEW package manager to this repository, you MUST:

1. Check whether it supports a minimum-release-age / exclude-newer / install-delay
   configuration option or environment variable.
2. If yes: configure it with `"5 days"` (or equivalent) in every shell layer:
   - POSIX: `src/modules/shell/env.nix` (env var) or `src/modules/shell.nix` (config file)
   - Windows: `src/hosts/Windows/user/env.dsc.yml` (DSC env var) +
     `src/hosts/Windows/modules/user/Sync-ShellProfile.ps1` (PowerShell profile)
3. If no: add a note to this table explaining why, and rely on lockfile pinning.
4. If an existing package manager gains a delay feature in an upstream update,
   add it and remove the "no delay feature" note.
5. Check whether the package manager supports an `--ignore-scripts` equivalent
   or `--no-build` equivalent. If yes, configure it in `src/modules/agents.nix`.
6. If the package manager uses lifecycle scripts, add its packages to
   `src/lockfiles/lifecycle-allowlist.json` with justifications.
7. Ensure CI uses the locked/locked-mode equivalent for that package manager
   (e.g., `--frozen`, `--locked`).

## Cross-host parity

Supply chain delay settings MUST be applied on every host (macOS, NixOS,
Windows) that runs the package manager. POSIX hosts share config through Nix
modules; Windows has separate DSC and PowerShell profile layers — all must be
kept in sync.

## flake.lock location

`src/flake.lock` is NOT a duplicate of anything under `src/lockfiles/`. Nix
requires `flake.lock` to be in the same directory as `flake.nix` (Nix does not
support alternative lockfile paths). `src/lockfiles/flake.lock` is a symlink
to `../flake.lock` for organizational consistency so all lockfiles can be
managed under `src/lockfiles/`. See `AGENTS.md` (Repository Shape) for details.

## References

- uv: https://docs.astral.sh/uv/reference/settings/#exclude-newer
- uv add-bounds: https://docs.astral.sh/uv/reference/settings/#add-bounds
- bun: https://bun.sh/docs/runtime/bunfig#install
- npm: https://docs.npmjs.com/cli/v11/using-npm/config#min-release-age
- pnpm: https://pnpm.io/blog/releases/10.16
- Yarn: https://github.com/yarnpkg/berry/releases/tag/%40yarnpkg%2Fcli%2F4.10.0
- Bundler: https://thehackernews.com/2026/06/threatsday-bulletin-ai-agents-gone.html
