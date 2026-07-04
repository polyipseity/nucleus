---
description: "Use when adding or modifying package manager installations, configuration, or setup scripts. Covers supply chain delay defaults enforced across all managed package managers."
name: "Supply Chain Hardening"
applyTo: "src/modules/shell*.nix, src/modules/agents.nix, src/modules/pwsh.nix, src/hosts/Windows/user/env.dsc.yml, src/hosts/Windows/modules/**/*.ps1"
---

# Supply Chain Hardening

All managed package managers in this repository MUST have a minimum release age
delay configured to limit exposure to newly published (potentially compromised)
package versions.

## Active delays (5 days)

| Package manager | Mechanism | Setting | File(s) |
|---|---|---|---|
| **bun** | `~/.bunfig.toml` | `[install] minimumReleaseAge = 432000` (5 days in seconds) | `src/modules/shell.nix` |
| **uv** | `UV_EXCLUDE_NEWER` env var | `"P5D"` (ISO 8601 duration) | `src/modules/shell/env.nix`, `src/hosts/Windows/user/env.dsc.yml`, `src/hosts/Windows/modules/user/Sync-ShellProfile.ps1` |

## Package managers without delay features

These are used but lack a built-in delay mechanism. They are managed through
explicit version pinning in `src/lockfiles/lockfile.json` instead:

- WinGet — no delay feature; rely on lockfile pinning
- Scoop — no delay feature; rely on lockfile pinning
- cargo-binstall — no delay feature; rely on lockfile pinning
- rustup — no delay feature; rely on lockfile pinning
- Homebrew — autoUpdate disabled globally; rely on lockfile pinning

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

## Cross-host parity

Supply chain delay settings MUST be applied on every host (macOS, NixOS,
Windows) that runs the package manager. POSIX hosts share config through Nix
modules; Windows has separate DSC and PowerShell profile layers — all must be
kept in sync.

## References

- uv: https://docs.astral.sh/uv/reference/settings/#exclude-newer
- bun: https://bun.sh/docs/runtime/bunfig#install
- npm: https://docs.npmjs.com/cli/v11/using-npm/config#min-release-age
- pnpm: https://pnpm.io/blog/releases/10.16
- Yarn: https://github.com/yarnpkg/berry/releases/tag/%40yarnpkg%2Fcli%2F4.10.0
- Bundler: https://thehackernews.com/2026/06/threatsday-bulletin-ai-agents-gone.html
