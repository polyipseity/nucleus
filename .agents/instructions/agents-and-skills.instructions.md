---
description: "Use when adding or editing agents configuration, skill management, or ClawHub provisioning."
name: "Agents and Skills"
applyTo: "src/modules/agents.nix, src/modules/cursor.nix, src/modules/hermes-agent.nix, src/platforms/Windows/modules/user/Sync-AgentsSkillManifest.ps1, src/platforms/Windows/modules/user/Sync-AgentsClawHubSkillManifest.ps1, src/platforms/Windows/modules/user/Sync-CursorConfig.ps1, src/platforms/Windows/modules/user/Sync-OpenCodeConfig.ps1, src/platforms/Windows/modules/user/Sync-PiAgentConfig.ps1, src/platforms/Windows/modules/user/Sync-SuperpowersPlugin.ps1, src/platforms/Windows/modules/user/Sync-NucleusAppShim.ps1, src/platforms/Windows/modules/setup/Invoke-BunSetup.ps1, src/platforms/Windows/modules/setup/Invoke-PiSetup.ps1, src/scripts/notify/**, src/users/*/agents/**, src/users/*/cursor/**, src/users/*/hermes/plugins/**, src/users/*/opencode/**, src/users/*/pi/**, src/users/*/srt/**, src/scripts/agents/**/*.sh, src/scripts/configs/symlink-cursor-config.sh, tests/modules/harness-bridge-tests.nix"
---

# Agents and skills

`.agents/` holds project assets; `src/users/default/agents/` overlays to writable `~/.agents/` with per-subdir symlinks. Cursor and Pi/opencode bridges link shared rules, agents, prompts, and skills; edit source trees, never deployed directories. Pi extensions come from `desired.json` and the lockfile, never from `~/.pi/agent/npm/`.

Commit MIT, BSD, Apache-2.0, or AGPL skills; never commit proprietary, CC-NC, or GPL-only skills. Those slugs go in `clawhub-skills.json` and are fetched at apply time, marked by `.clawhub/origin.json`. Layered skills use an overlay source directory, never a hardcoded `src/modules/configs/agents/skills` path. Installed files are read-only and unlocked before update; ClawHub installs only through bun.

The harness bridge runs scripts from `src/scripts/notify/harness/` through `nucleus-utils`, filters from `harness-filters.json`, and denies over ask over allow with no allow by omission. Hooks exit 0, wait timeouts are ceilings, commands stay bare names, and queued prompts are consumed before printing. `harness-notify.enable` is master, approval sources race, and drive gates only prompt injection. Sandbox socket spellings and File Provider identity rules are in the reference.

Details: `src/users/default/agents/skills/nucleus-harness-reference/references/agents-and-skills.md` and the three harness reference files.
