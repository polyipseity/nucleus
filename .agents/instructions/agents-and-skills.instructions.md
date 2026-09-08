---
description: "Use when adding or editing agents configuration, skill management, or ClawHub provisioning."
name: "Agents and Skills"
applyTo: "src/modules/agents.nix, src/modules/cursor.nix, src/platforms/Windows/modules/user/Sync-AgentsSkillManifest.ps1, src/platforms/Windows/modules/user/Sync-AgentsClawHubSkillManifest.ps1, src/platforms/Windows/modules/user/Sync-CursorConfig.ps1, src/platforms/Windows/modules/setup/Invoke-BunSetup.ps1, src/users/*/agents/**, src/users/*/cursor/**, src/scripts/agents/**/*.sh, src/scripts/configs/symlink-cursor-config.sh"
---

# Agents and Skills

## Repo vs user overlay

| Tree | Path | Role |
| --- | --- | --- |
| **Repo** | `.agents/` | Project instructions, repo-tied skills, OpenCode/Copilot loading |
| **User overlay** | `src/users/default/agents/` | Global config → `~/.agents/` |

`.agents/skills/` = project-tied (`pssa-rule-benchmark`, `sf-symbols`). `src/users/default/agents/skills/` = workflow (`checkpoint`, `asciinema`, `chronicler`, `humanizer`). `.agents/agents/.gitkeep` = placeholder for `.opencode/agents` symlink + VS Code `chat.agentFilesLocations`. Real definitions in `src/users/default/agents/agents/`.

## Directory layout

`~/.agents/` = writable dir with per-subdir symlinks (not whole-dir symlink).

| Path | Owner | Purpose |
| --- | --- | --- |
| `~/.agents/` | `symlink-agent-config` | Per-subdir symlinks for `src/users/<user>/agents/` entries except `skills/` |
| `~/.agents/hooks/` | `symlink-agent-config` | VS Code Copilot hooks (`PreToolUse`/`PostToolUse`), loaded via `chat.hookFilesLocations` |
| `~/.agents/skills/<name>/` (symlink) | `install-agent-skills` | Bundled skill from `src/users/default/agents/skills/<name>/` |
| `~/.agents/skills/<name>/` (real dir) | `sync-clawhub-skills` | Fetched skill; `.clawhub/origin.json` marker |

`~/.agents/` files are symlinks, not source of truth. Edit under `src/users/default/agents/` (or per-user overrides); `~/.agents/` overwritten on apply.

## Cursor bridge (`~/.cursor/`)

`symlink-cursor-config` / `Sync-CursorConfig` bridges shared content:

| `~/.cursor/` | Source | Mechanism |
| --- | --- | --- |
| `skills/` | `~/.agents/skills/` | Folder symlink |
| `rules/*.mdc` | `~/.agents/instructions/*.instructions.md` | Per-file symlink (`.mdc` required) |
| `agents/*.md` | `~/.agents/agents/*.agent.md` | Per-file symlink |
| `commands/*.md` | `~/.agents/prompts/*.prompt.md` | Per-file symlink |
| `hooks.json`, `mcp.json` | `src/users/default/cursor/` | Per-entry symlink |

Edit shared rules/agents/prompts/skills under `src/users/default/agents/`, not `~/.cursor/`. Cursor-native JSON under `src/users/default/cursor/`. Cursor GUI settings (`cursor.aiprovider.*`) live in app-level user settings, not `~/.cursor/` CLI overlay.

## Bundled vs. fetched skills

**Bundled** (AGPL-compatible: MIT, BSD, Apache-2.0, AGPL): commit to `src/users/default/agents/skills/<name>/`. `install-agent-skills` symlinks into store.

**Fetched** (incompatible: proprietary, CC-NC, GPL-only): never commit; list slug in `src/users/default/agents/clawhub-skills.json` under `"skills"`. `sync-clawhub-skills` downloads at apply time.

`.clawhub/origin.json` marks fetched downloads. Stale cleanup checks for it before removal. Slug matching existing bundled symlink → activation warns and skips; resolve manually.

## Permission locking

Installed files locked read-only. Lock cleared before update for overwrite.

- **POSIX**: `chmod -R a-w` after; `chmod -R u+w` before.
- **Windows**: `FileAttributes.ReadOnly` via `Get-ChildItem -Recurse` after; same loop before.
- Windows `Sync-NucleusSecretFile` uses `$restrictAcl` (`icacls /inheritance:r /grant:r`) on top.

## ClawHub provisioning

ClawHub = JS CLI not in nixpkgs/cargo-binstall/WinGet/Scoop. Bun only.

### POSIX

`install-bun-packages` HM activation in `src/modules/agents.nix`:

1. Prepends `~/.bun/bin` to PATH. Guards bun on PATH.
2. Maintains desired list (`clawhub` only). Installs missing, removes unwanted (`bun remove -g`).
3. Persists to `~/.bun/install/global/package.json`.

### Windows

`Invoke-BunSetup` (`src/platforms/Windows/modules/setup/Invoke-BunSetup.ps1`) manages `$desiredPackages` (`@mariozechner/pi-coding-agent`, `clawhub`) → `~\.bun\install\global\package.json`. Order: WinGet DSC → `Invoke-BunSetup` → `Sync-AgentsSkillManifest` → `Sync-AgentsClawHubSkillManifest`.

## Authoring rules

- Sync functions must not install ClawHub — provisioning via `install-bun-packages` / `Invoke-BunSetup`.
- Stale cleanup: only remove dirs with `.clawhub/origin.json`.
- Skill sync is best-effort: warn on failure, continue.
- Package lists sorted alphabetically.
