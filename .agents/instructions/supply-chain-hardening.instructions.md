---
description: "Use when adding or modifying package manager installations, configuration, or setup scripts. Covers supply chain delay defaults enforced across all managed package managers."
name: "Supply Chain Hardening"
applyTo: "src/modules/shell/**, src/modules/agents.nix, src/modules/pwsh.nix, src/hosts/Windows/user/env.dsc.yml, src/platforms/Windows/modules/**/*.ps1, scripts/check.sh, scripts/check.ps1, scripts/update.sh, scripts/update.ps1, src/lockfiles/lifecycle-allowlist.json"
---

# Supply chain hardening

Every managed package manager gets a release-age delay. Authoritative values live in `src/modules/configs/release-ages.json` with its schema; all consumers must match (`run_release_age_uniformity`). bun uses `~/.bunfig.toml` `[install] minimumReleaseAge = 432000` (5 days) with `exact = true`; uv uses `uv.toml` `exclude-newer = "P5D"` with `add-bounds = "exact"`; PSGallery has no upstream delay, so entries carry version plus nupkg SHA256.

WinGet, Scoop, cargo-binstall, rustup, and Homebrew have no delay and rely on lockfile pins; Homebrew disables activation updates and upgrades. `bun install -g` uses `--ignore-scripts` except allowlisted entries and `--linker hoisted`; `uv tool install` uses `--no-build`. Allowlist entries require reviewed lifecycle scripts and justifications. Check steps always validate lockfile structure and the allowlist; `--online` adds freshness and yanked detection.

A new package manager needs delay configuration, script blocking, allowlist entries, locked CI mode, and a gap note when upstream lacks a feature. Details: `.agents/skills/nucleus-policy-reference/references/supply-chain-hardening.md`.
