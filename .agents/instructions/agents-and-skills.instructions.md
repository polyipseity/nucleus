---
description: "Use when adding or editing agents configuration, skill management, or ClawHub provisioning."
name: "Agents and Skills"
applyTo: "src/modules/agents.nix, src/modules/cursor.nix, src/platforms/Windows/modules/user/Sync-AgentsSkillManifest.ps1, src/platforms/Windows/modules/user/Sync-AgentsClawHubSkillManifest.ps1, src/platforms/Windows/modules/user/Sync-CursorConfig.ps1, src/platforms/Windows/modules/user/Sync-OpenCodeConfig.ps1, src/platforms/Windows/modules/user/Sync-PiAgentConfig.ps1, src/platforms/Windows/modules/user/Sync-Superpowers.ps1, src/platforms/Windows/modules/setup/Invoke-BunSetup.ps1, src/platforms/Windows/modules/setup/Invoke-PiSetup.ps1, src/users/*/agents/**, src/users/*/cursor/**, src/scripts/agents/**/*.sh, src/scripts/configs/symlink-cursor-config.sh"
---

# Agents and Skills

## Repo vs user overlay

| Tree | Path | Role |
| --- | --- | --- |
| **Repo** | `.agents/` | Project instructions, repo-tied skills, OpenCode/Copilot loading |
| **User overlay** | `src/users/default/agents/` | Global config → `~/.agents/` |

`.agents/skills/` = project-tied (`pssa-rule-benchmark`, `sf-symbols`). `src/users/default/agents/skills/` = workflow (`checkpoint`, `asciinema`, `chronicler`, `humanizer`). `.agents/agents/.gitkeep` = placeholder for `.opencode/agents` symlink. Real definitions in `src/users/default/agents/agents/`.

## Directory layout

`~/.agents/` = writable dir with per-subdir symlinks (not whole-dir symlink). `~/.agents/` files are symlinks, not source of truth — edit under `src/users/default/agents/` (or per-user overrides).

| Path | Owner | Purpose |
| --- | --- | --- |
| `~/.agents/hooks/` | `symlink-agent-config` | VS Code Copilot hooks, loaded via `chat.hookFilesLocations` |
| `~/.agents/skills/<name>/` (symlink) | `install-agent-skills` | Bundled skill from `src/users/default/agents/skills/<name>/` |
| `~/.agents/skills/<name>/` (real dir) | `sync-clawhub-skills` | Fetched skill; `.clawhub/origin.json` marker |

## Cursor bridge (`~/.cursor/`)

`symlink-cursor-config` / `Sync-CursorConfig` bridges shared content:

| `~/.cursor/` | Source | Mechanism |
| --- | --- | --- |
| `skills/` | `~/.agents/skills/` | Folder symlink |
| `rules/*.mdc` | `~/.agents/instructions/*.instructions.md` | Per-file symlink (`.mdc` required) |
| `agents/*.md` | `~/.agents/agents/*.agent.md` | Per-file symlink |
| `commands/*.md` | `~/.agents/prompts/*.prompt.md` | Per-file symlink |
| `hooks.json`, `mcp.json` | `src/users/default/cursor/` | Per-entry symlink |

Edit shared rules/agents/prompts/skills under `src/users/default/agents/`, not `~/.cursor/`. Cursor-native JSON under `src/users/default/cursor/`. GUI settings in app-level user settings, not `~/.cursor/` CLI overlay.

## Agent config bridges (`~/.pi/`, `~/.config/opencode/`)

`symlink-pi-agent-config` / `Sync-PiAgentConfig` and `symlink-agent-config` / `Sync-OpenCodeConfig` bridge the shared agent assets into the coding agents' own config trees:

| Target | Source | Mechanism |
| --- | --- | --- |
| `~/.pi/agent/extensions` | `src/users/<user>/agents/pi-extensions` | Writable symlink (method 1) |
| `~/.pi/agent/settings.json` | `src/users/<user>/agents/pi-settings.json` | Writable symlink (method 1) |
| `~/.config/opencode/opencode.jsonc` | `src/users/<user>/agents/opencode.jsonc` | Writable symlink (method 1) |
| `~/.config/opencode/agents` | `~/.agents/agents` | Writable symlink (method 1) |
| `~/.config/opencode/commands` | `~/.agents/prompts` | Writable symlink (method 1) |

Windows resolves the same sources through the `Resolve-UserConfig*` overlay helpers; opencode uses `~/.config/opencode/` on every platform, including `%USERPROFILE%\.config\opencode\`. Pi's own extension set is converged by `install-pi-packages` / `Invoke-PiSetup` from the `pi` list in `src/modules/packages/desired.json`, pinned by the lockfile `pi` section — pi records installed extensions in `~/.pi/agent/settings.json`, which is the registry those steps read (never a directory listing of `~/.pi/agent/npm/`, which contains `node_modules`).

## Bundled vs. fetched skills

**Bundled** (AGPL-compatible: MIT, BSD, Apache-2.0, AGPL): commit to `src/users/default/agents/skills/<name>/`. `install-agent-skills` symlinks into store.

**Fetched** (incompatible: proprietary, CC-NC, GPL-only): never commit; list slug in `src/users/default/agents/clawhub-skills.json`. `sync-clawhub-skills` downloads at apply time. `.clawhub/origin.json` marks fetched downloads — stale cleanup checks for it before removal. Slug matching bundled symlink → warns and skips; resolve manually.

**Layered**: `install-agent-skills` / `Sync-AgentsSkillManifest` accept an extra source directory, used to layer the superpowers plugin's `skills/` into `~/.agents/skills/` alongside the committed skills. The primary source is the `skills` entry of the agents overlay, resolved through the overlay helpers — never a hardcoded `src/modules/configs/agents/skills` path.

## Permission locking

Installed files locked read-only; lock cleared before update. POSIX: `chmod -R a-w`/`u+w`. Windows: `FileAttributes.ReadOnly` via `Get-ChildItem -Recurse`. `Sync-NucleusSecretFile` adds `$restrictAcl` (`icacls /inheritance:r /grant:r`).

## ClawHub provisioning

ClawHub = JS CLI not in nixpkgs/cargo-binstall/WinGet/Scoop. Bun only.

**POSIX**: `install-bun-packages` HM activation in `src/modules/agents.nix` — prepends `~/.bun/bin`, maintains desired list (`clawhub`), installs/removes as needed, persists to `~/.bun/install/global/package.json`.

**Windows**: `Invoke-BunSetup` manages `$desiredPackages` (`@mariozechner/pi-coding-agent`, `clawhub`) → `~\.bun\install\global\package.json`. Order: WinGet DSC → `Invoke-BunSetup` → `Sync-AgentsSkillManifest` → `Sync-AgentsClawHubSkillManifest`.

## Authoring rules

- Sync functions must not install ClawHub — provisioning via `install-bun-packages` / `Invoke-BunSetup`.
- Stale cleanup: only remove dirs with `.clawhub/origin.json`.
- Skill sync is best-effort: warn on failure, continue.
- Package lists sorted alphabetically.
