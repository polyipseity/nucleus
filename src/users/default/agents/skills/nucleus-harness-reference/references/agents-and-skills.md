---
description: "Use when adding or editing agents configuration, skill management, or ClawHub provisioning."
name: "Agents and Skills"
applyTo: "src/modules/agents.nix, src/modules/cursor.nix, src/modules/hermes-agent.nix, src/platforms/Windows/modules/user/Sync-AgentsSkillManifest.ps1, src/platforms/Windows/modules/user/Sync-AgentsClawHubSkillManifest.ps1, src/platforms/Windows/modules/user/Sync-CursorConfig.ps1, src/platforms/Windows/modules/user/Sync-OpenCodeConfig.ps1, src/platforms/Windows/modules/user/Sync-PiAgentConfig.ps1, src/platforms/Windows/modules/user/Sync-SuperpowersPlugin.ps1, src/platforms/Windows/modules/user/Sync-NucleusAppShim.ps1, src/platforms/Windows/modules/setup/Invoke-BunSetup.ps1, src/platforms/Windows/modules/setup/Invoke-PiSetup.ps1, src/scripts/notify/**, src/users/*/agents/**, src/users/*/cursor/**, src/users/*/hermes/plugins/**, src/users/*/opencode/**, src/users/*/pi/**, src/users/*/srt/**, src/scripts/agents/**/*.sh, src/scripts/configs/symlink-cursor-config.sh, tests/modules/harness-bridge-tests.nix"
---

# Agents and skills

`.agents/` holds project instructions, prompts, and skills. `src/users/default/agents/` overlays to `~/.agents/`, with per-user overrides under `src/users/<user>/agents/`. Edit source, never `~/.agents/`; that directory is writable with per-subdir symlinks, not one whole-directory symlink.

`symlinkCursorConfig` / `Sync-CursorConfig` link shared content into `~/.cursor/`; `.md` instructions reach `~/.cursor/rules/` as `.mdc`. Shared rules live in `src/users/default/agents/`, Cursor JSON in `src/users/default/cursor/`, GUI settings in app settings. Pi and opencode bridges (`symlinkPiAgentConfig` / `Sync-PiAgentConfig`, `symlinkAgentConfig` / `Sync-OpenCodeConfig`) deploy to `~/.pi/agent/` and `~/.config/opencode/` (Windows `%USERPROFILE%\.config\opencode\`), resolving sources through `Resolve-UserConfig*`. Pi extensions come from the `pi` entry in `src/modules/packages/desired.json` pinned by the lockfile and recorded in `~/.pi/agent/settings.json`; never list `~/.pi/agent/npm/` (`node_modules`).

Commit MIT, BSD, Apache-2.0, and AGPL skills to `src/users/default/agents/skills/<name>/`. Never commit proprietary, CC-NC, or GPL-only skills; list the slug in `src/users/default/agents/clawhub-skills.json` and let `syncClawhubSkills` fetch it at apply time. `.clawhub/origin.json` marks fetched downloads and stale removal touches only those directories; a slug matching a bundled symlink warns and skips. Layered skills use an extra source directory accepted by `installAgentSkills` / `Sync-AgentsSkillManifest` for the superpowers `skills/` tree, resolved from the overlay's `skills` entry, never a hardcoded `src/modules/configs/agents/skills` path.

Installed files are read-only and unlocked before update: POSIX `chmod -R a-w` / `u+w`, Windows `FileAttributes.ReadOnly` via `Get-ChildItem -Recurse`, and `Sync-SecretFile` adds `$restrictAcl` (`icacls /inheritance:r /grant:r`).

ClawHub installs through bun only: absent from nixpkgs, cargo-binstall, WinGet, and Scoop. POSIX uses `installBunPackages` in `src/modules/agents.nix` (prepends `~/.bun/bin`, persists `~/.bun/install/global/package.json`); Windows `Invoke-BunSetup` installs the `bun` desired list into the same file after WinGet DSC and before skill syncs.

Authoring rules:

- Sync functions must not install ClawHub; provisioning is `installBunPackages` / `Invoke-BunSetup`.
- Skill sync is best-effort: warn on failure, continue.
- Package lists are sorted alphabetically.

Harness bridge and sandbox detail lives in `harness-bridge.md`; capability lookup in `harness-adapters.md`; capability status in `harness-capabilities.md`.
