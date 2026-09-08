---
description: "Use when adding or editing agents configuration, skill management, or ClawHub provisioning. Covers ~/.agents directory layout, bundled vs. fetched skill licensing rules, permission patterns, and the install-bun-packages/sync-clawhub-skills activation DAG."
name: "Agents and Skills"
applyTo: "src/modules/agents.nix, src/modules/cursor.nix, src/platforms/Windows/modules/user/Sync-AgentsSkillManifest.ps1, src/platforms/Windows/modules/user/Sync-AgentsClawHubSkillManifest.ps1, src/platforms/Windows/modules/user/Sync-CursorConfig.ps1, src/platforms/Windows/modules/setup/Invoke-BunSetup.ps1, src/users/*/agents/**, src/users/*/cursor/**, src/scripts/agents/**/*.sh, src/scripts/configs/symlink-cursor-config.sh"
---

# Agents and Skills

## Repo vs user overlay

| Tree | Path | Role |
| ---- | ---- | ---- |
| **Repo** | `.agents/` | Project-specific instructions, repo-tied skills, OpenCode/Copilot loading |
| **User overlay** | `src/users/default/agents/` | Global agent config → `~/.agents/` |

`.agents/skills/` = **project-tied** skills (`pssa-rule-benchmark`, `sf-symbols`). `src/users/default/agents/skills/` = **workflow** skills (`checkpoint`, `asciinema`, `chronicler`, `humanizer`).

`.agents/agents/.gitkeep` = empty placeholder for `.opencode/agents` symlink and VS Code `chat.agentFilesLocations`. Real definitions live in `src/users/default/agents/agents/`.

## Directory layout

`~/.agents/` is a real writable directory with per-subdir symlinks (not a whole-directory symlink).

| Path | Owner | Purpose |
| ------------------------------------- | -------------------------------------------------- | ---- |
| `~/.agents/` | `symlink-agent-config` | Per-subdir symlinks for resolved `src/users/<user>/agents/` entries except `skills/` |
| `~/.agents/hooks/` | `symlink-agent-config` | VS Code Copilot hook configs (`PreToolUse`/`PostToolUse`), loaded via `chat.hookFilesLocations` |
| `~/.agents/skills/` | `install-agent-skills` | Per-skill symlinks (bundled) + real dirs (fetched) |
| `~/.agents/skills/<name>/` (symlink) | `install-agent-skills` | Bundled skill from `src/users/default/agents/skills/<name>/` |
| `~/.agents/skills/<name>/` (real dir) | `sync-clawhub-skills` | Fetched skill; `.clawhub/origin.json` marker |

Files in `~/.agents/` are symlinks into the overlay — not source of truth. Edit under `src/users/default/agents/` (or per-user overrides); `~/.agents/` changes are overwritten on apply.

## Cursor bridge (`~/.cursor/`)

`symlink-cursor-config` / `Sync-CursorConfig` bridges shared content from `src/users/default/agents/` into `~/.cursor/`:

| `~/.cursor/` | Source | Mechanism |
| ------------ | ----------------------------- | --------- |
| `skills/` | `~/.agents/skills/` | Folder symlink |
| `rules/*.mdc` | `~/.agents/instructions/*.instructions.md` | Per-file symlink (`.mdc` required) |
| `agents/*.md` | `~/.agents/agents/*.agent.md` | Per-file symlink |
| `commands/*.md` | `~/.agents/prompts/*.prompt.md` | Per-file symlink |
| `hooks.json`, `mcp.json` | `src/users/default/cursor/` | Per-entry symlink (Cursor-native only) |

Edit shared rules/agents/prompts/skills under `src/users/default/agents/`, not `~/.cursor/`. Cursor-native JSON under `src/users/default/cursor/`. Cursor GUI settings (`cursor.aiprovider.*`) live in app-level user settings (`~/Library/Application Support/Cursor/User/settings.json` on macOS, `%APPDATA%\Cursor\User\settings.json` on Windows), not in the `~/.cursor/` CLI overlay.

## Bundled vs. fetched skills

**Bundled** (AGPL-compatible: MIT, BSD, Apache-2.0, AGPL): commit files to `src/users/default/agents/skills/<name>/`. `install-agent-skills` symlinks into the store.

**Fetched** (incompatible: proprietary, CC-NC, GPL-only without linking exception): never commit; list slug in `src/users/default/agents/clawhub-skills.json` under `"skills"`. `sync-clawhub-skills` downloads at apply time via ClawHub.

The `.clawhub/origin.json` marker indicates a fetched download. Stale cleanup checks for it before removal — bundled symlinks and user content are never removed. If a slug matches an existing bundled symlink in `~/.agents/skills/`, activation warns and skips; resolve the naming conflict manually.

## Permission locking

Installed skill files are locked read-only after install/update. Lock cleared before update so clawhub can overwrite.

- **POSIX**: `chmod -R a-w` after; `chmod -R u+w` before.
- **Windows**: `FileAttributes.ReadOnly` via `Get-ChildItem -Recurse` after; same loop before.
- Windows `Sync-NucleusSecretFile` secret/manifest files use `$restrictAcl` (`icacls /inheritance:r /grant:r`) on top of `ReadOnly`.

## ClawHub provisioning

ClawHub is a JS CLI tool not in nixpkgs/cargo-binstall/WinGet/Scoop — bun is the only install tier.

### POSIX

`install-bun-packages` HM activation in `src/modules/agents.nix`:

1. Prepends `~/.bun/bin` to `PATH`.
2. Guards `bun` on `PATH` (from `pkgs.bun` via `core.nix`).
3. Maintains desired-state list (`clawhub` only).
4. Installs packages whose binary is absent from `~/.bun/bin`.
5. Removes unwanted packages (`bun remove -g`).
6. Persists to bun's global `package.json` (`~/.bun/install/global/package.json`).

### Windows

`Invoke-BunSetup` (`src/platforms/Windows/modules/setup/Invoke-BunSetup.ps1`) manages `$desiredPackages` (currently `@mariozechner/pi-coding-agent` and `clawhub`) → writes to `%USERPROFILE%\.bun\install\global\package.json`. Order: WinGet DSC → `Invoke-BunSetup` → `Sync-AgentsSkillManifest` → `Sync-AgentsClawHubSkillManifest`.

## Authoring rules

- Sync functions must not install ClawHub themselves — provisioning belongs to `install-bun-packages` / `Invoke-BunSetup`.
- Stale cleanup: only remove directories with `.clawhub/origin.json`.
- Skill sync is best-effort: warn on failure, continue.
- Desired-package lists sorted alphabetically.
