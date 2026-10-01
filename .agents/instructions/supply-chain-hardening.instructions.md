---
description: "Use when adding or modifying package manager installations, configuration, or setup scripts. Covers supply chain delay defaults enforced across all managed package managers."
name: "Supply Chain Hardening"
applyTo: "src/modules/shell/**, src/modules/agents.nix, src/modules/pwsh.nix, src/hosts/Windows/user/env.dsc.yml, src/platforms/Windows/modules/**/*.ps1, scripts/check.sh, scripts/check.ps1, scripts/update.sh, scripts/update.ps1, src/lockfiles/lifecycle-allowlist.json"
---

# Supply chain hardening

Every managed package manager gets a minimum release age delay, limiting exposure to a compromised newly published version. The delay settings are identical on every host: POSIX shares them through Nix modules, Windows keeps its own DSC and PowerShell layers.

| Package manager | Mechanism | Setting | File(s) |
| --------------- | ---------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `bun` | `~/.bunfig.toml` | `[install] minimumReleaseAge = 432000` (5 days in seconds), `exact = true` | `src/modules/shell/default.nix`, `src/platforms/Windows/modules/user/Sync-ShellProfile.ps1` |
| `uv` | `uv.toml` | `exclude-newer = "P5D"` (ISO 8601 duration) + `add-bounds = "exact"` | `src/modules/shell/default.nix`, `src/platforms/Windows/modules/user/Sync-ShellProfile.ps1` |
| `PSGallery` | none upstream | version pin, plus the nupkg SHA256 (`hash`) for hash-pinned entries | `src/lockfiles/lockfile.json` (`psgallery`) |

WinGet, Scoop, cargo-binstall, rustup, and Homebrew have no delay feature, so they rely on the version pins in `src/lockfiles/lockfile.json`; Homebrew also disables `autoUpdate` globally. PSGallery cannot be proxied through a delayed source at all: it has no release-age feature and nixpkgs packages none of the modules pinned under `psgallery`, which is why that section carries the pin plus the nupkg SHA256.

## Lifecycle scripts

`bun install -g` uses `--ignore-scripts`, except for packages in `src/lockfiles/lifecycle-allowlist.json`, which the installer reads and skips the flag for. It also needs `--linker hoisted`: the machine-wide `install.linker = "isolated"` leaves `$BUN_INSTALL/bin` unlinked for global installs (oven-sh/bun#30450), so the binary never reaches PATH.

`uv tool install` uses `--no-build` to require pre-built wheels. A package without pre-built wheels goes through review and into the allowlist.

To add an allowlist entry, review the lifecycle scripts, write the justification, and confirm the scripts are necessary and not replaceable by a locked alternative. Validation in `check.sh` and `check.ps1`: the file exists, parses as JSON, and every entry has a non-empty justification (`allow-and-deny-lists.instructions.md#D2`).

## Lockfile validation

`check.sh` and `check.ps1` always run, even in path-scoped mode: lockfile.json exists with a valid schema, no package name appears in two sections except where `allow-and-deny-lists.instructions.md#D1` allows it, and the lifecycle allowlist validates. With `--online` and network, they add freshness (`update.sh lockfile --verify` diffs against the registries) and yanked/removed detection.

## Adding a package manager

1. Delay support (`minimum-release-age`, `exclude-newer`, install-delay env var) means configuring "5 days" in `src/modules/shell/default.nix` and `src/platforms/Windows/modules/user/Sync-ShellProfile.ps1`; without it, note the gap in the table above and rely on lockfile pinning.
2. Script-blocking support (`--ignore-scripts`, `--no-build`) is configured in `src/modules/agents.nix`.
3. Required lifecycle scripts go into `src/lockfiles/lifecycle-allowlist.json` with justifications.
4. CI has to use locked mode (`--frozen`, `--locked`).
5. If upstream later adds a delay feature, configure it and drop the note.
