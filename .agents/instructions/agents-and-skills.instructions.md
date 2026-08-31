---
description: "Use when adding or editing agents configuration, skill management, or ClawHub provisioning. Covers ~/.agents directory layout, bundled vs. fetched skill licensing rules, permission patterns, and the install-bun-packages/sync-clawhub-skills activation DAG."
name: "Agents and Skills"
applyTo: "src/modules/agents.nix, src/modules/cursor.nix, src/platforms/Windows/modules/user/Sync-AgentsSkillManifest.ps1, src/platforms/Windows/modules/user/Sync-AgentsClawHubSkillManifest.ps1, src/platforms/Windows/modules/user/Sync-CursorConfig.ps1, src/platforms/Windows/modules/setup/Invoke-BunSetup.ps1, src/users/*/agents/**, src/users/*/cursor/**, src/scripts/agents/**/*.sh, src/scripts/configs/symlink-cursor-config.sh"
---

# Agents and Skills

## Repo vs user overlay

| Tree | Path | Role |
| ---- | ---- | ---- |
| **Repo policy** | `.agents/` | Project-specific instructions, repo-tied skills, OpenCode/Copilot workspace loading |
| **User overlay** | `src/users/default/agents/` | Global agent config provisioned to `~/.agents/` |

Repo `.agents/skills/` holds **project-tied** skills (`pssa-rule-benchmark`, `sf-symbols`). User overlay `src/users/default/agents/skills/` holds **workflow** skills (`checkpoint`, `asciinema`, `chronicler`, `humanizer`).

`.agents/agents/.gitkeep` is an intentional empty placeholder for the `.opencode/agents` symlink and VS Code `chat.agentFilesLocations`. Real agent definitions live in `src/users/default/agents/agents/`.

## Directory layout

The `~/.agents/` directory is the runtime home for agent configuration, prompts, skills, and hooks — a real (writable) directory with per-subdirectory symlinks, not a whole-directory symlink.

| Path | Owner | Purpose |
| ------------------------------------- | -------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `~/.agents/` | `symlink-agent-config` activation | Per-subdir symlinks for every resolved `src/users/<user>/agents/` entry except `skills/` |
| `~/.agents/hooks/` | `symlink-agent-config` activation | VS Code Copilot hook configs (`PreToolUse`/`PostToolUse`), loaded via `chat.hookFilesLocations` |
| `~/.agents/skills/` | `install-agent-skills` activation | Per-skill symlinks for bundled skills + real dirs for fetched skills |
| `~/.agents/skills/<name>/` (symlink) | `install-agent-skills` | Bundled skill committed to `src/users/default/agents/skills/<name>/` |
| `~/.agents/skills/<name>/` (real dir) | `sync-clawhub-skills` / `Sync-AgentsClawHubSkillManifest` | Fetched skill downloaded by ClawHub; contains a `.clawhub/origin.json` marker |

## Cursor bridge (`~/.cursor/`)

Cursor reads different path names than Copilot/OpenCode. Shared content stays in `src/users/default/agents/` (provisioned to `~/.agents/` via per-user overlay). The `symlink-cursor-config` activation / `Sync-CursorConfig` bridges into `~/.cursor/`:

| `~/.cursor/` | Source (`~/.agents/` or repo) | Mechanism |
| ------------ | ----------------------------- | --------- |
| `skills/` | `~/.agents/skills/` | Folder symlink |
| `rules/*.mdc` | `~/.agents/instructions/*.instructions.md` | Per-file symlink (Cursor requires `.mdc` extension) |
| `agents/*.md` | `~/.agents/agents/*.agent.md` | Per-file symlink |
| `commands/*.md` | `~/.agents/prompts/*.prompt.md` | Per-file symlink |
| `hooks.json`, `mcp.json`, … | `src/users/default/cursor/` | Per-entry symlink (Cursor-native only) |

Edit shared rules/agents/prompts/skills under `src/users/default/agents/` (or per-user overrides under `src/users/<username>/agents/`), not under `~/.cursor/`. Edit Cursor-native JSON under `src/users/default/cursor/`.

Cursor's GUI model/API settings (`cursor.aiprovider.openai.baseUrl` / `apiKey` / `model`) live in the app-level user settings (`~/Library/Application Support/Cursor/User/settings.json` on macOS, `%APPDATA%\Cursor\User\settings.json` on Windows), NOT in the `~/.cursor/` CLI overlay (`cli-config.json`, `mcp.json`, `hooks.json`).

The per-subdir layout lets `skills/` be writable without writes entering Git.

Files in `~/.agents/` are per-entry symlinks into the resolved overlay directory — not the source of truth. Always edit under `src/users/default/agents/` (or per-user overrides); changes to `~/.agents/` are overwritten on the next apply.

## Bundled vs. fetched skills

**Bundled**: license compatible with AGPL inclusion (MIT, BSD, Apache-2.0, AGPL) → commit all skill files to `src/users/default/agents/skills/<name>/`. The `install-agent-skills` activation symlinks `~/.agents/skills/<name>` into the store.

**Fetched**: licenses incompatible with AGPL inclusion (e.g., proprietary, CC-NC, GPL-only without linking exception) → never commit; list the skill slug in `src/users/default/agents/clawhub-skills.json` under `"skills"`. The `sync-clawhub-skills` activation downloads skills at apply time via the ClawHub CLI.

The `.clawhub/origin.json` marker is the only reliable indicator of a fetched download. Stale cleanup must check for it before removing any directory — bundled symlinks and user content are never removed.

If a slug in `clawhub-skills.json` matches an existing committed-skill symlink in `~/.agents/skills/`, the activation warns and skips that slug. The operator must resolve the naming conflict before ClawHub can write there.

## Permission locking

Installed skill files are locked read-only after each install or update. The lock is cleared before an update so clawhub can overwrite existing files.

**POSIX**: `chmod -R a-w` after install; `chmod -R u+w` before update/cleanup.

**Windows**: `FileAttributes.ReadOnly` set via `Get-ChildItem -Recurse` after install; cleared via the same loop before update/cleanup.

Secret and manifest files written by `Sync-NucleusSecretFile` on Windows use a stricter `$restrictAcl` block (`icacls /inheritance:r /grant:r`) on top of `ReadOnly` for owner-only access.

## ClawHub provisioning

ClawHub is the install vehicle for fetched skills. It is a JS CLI tool absent from nixpkgs, cargo-binstall, WinGet, and Scoop — bun is therefore the only viable install tier.

### POSIX

ClawHub is installed and managed declaratively by the `install-bun-packages` Home Manager activation in `src/modules/agents.nix`. The activation:

1. Prepends `~/.bun/bin` to `PATH` for the current session.
2. Guards that `bun` is on `PATH` (provided by `pkgs.bun` via `core.nix`).
3. Maintains a desired-state list (`clawhub` is the only current entry).
4. Installs packages whose binary is absent from `~/.bun/bin`.
5. Removes packages no longer desired (via `bun remove -g`).
6. Persists the managed set to bun's global `package.json` (`~/.bun/install/global/package.json`).

### Windows

ClawHub is managed by `Invoke-BunSetup` in `src/platforms/Windows/modules/setup/Invoke-BunSetup.ps1`, which is called by `apply.ps1` before `Sync-AgentsClawHubSkillManifest`. `Invoke-BunSetup` manages a `$desiredPackages` list (currently `@mariozechner/pi-coding-agent` and `clawhub`) and writes a manifest to bun's global `package.json` (`%USERPROFILE%\.bun\install\global\package.json`). Applied in this order: WinGet DSC → `Invoke-BunSetup` (bun global packages) → `Sync-AgentsSkillManifest` (bundled skill symlinks) → `Sync-AgentsClawHubSkillManifest` (fetched skill downloads).

## Authoring rules

- No fallback installs in sync functions: POSIX `sync-clawhub-skills` and Windows `Sync-AgentsClawHubSkillManifest` must not install ClawHub themselves. Provisioning belongs to `install-bun-packages` / `Invoke-BunSetup`.
- Stale cleanup scoped to fetched downloads: only remove directories with a `.clawhub/origin.json` marker.
- Skill sync is best-effort: log a warning on failure and continue.
- Desired-package lists sorted alphabetically.
