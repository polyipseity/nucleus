---
description: "Use when adding or editing agents configuration, skill management, or ClawHub provisioning. Covers ~/.agents directory layout, bundled vs. fetched skill licensing rules, permission patterns, and the installBunPackages/syncClawHubSkills activation DAG."
name: "Agents and Skills"
applyTo: "src/modules/agents.nix, src/hosts/Windows/modules/user/Sync-AgentsSkill.ps1, src/hosts/Windows/modules/user/Sync-AgentsClawHubSkill.ps1, src/hosts/Windows/modules/setup/Invoke-BunSetup.ps1, src/modules/configs/agents/**"
---

# Agents and Skills

## Directory layout

The `~/.agents/` directory is the runtime home for all agent configuration, prompts, and skills. It is a real (writable) directory, **not** a whole-dir symlink into the repo tree.

| Path                                  | Owner                                            | Purpose                                                                                            |
| ------------------------------------- | ------------------------------------------------ | -------------------------------------------------------------------------------------------------- |
| `~/.agents/`                          | `agentsSymlink` activation                       | Real directory; per-subdir symlinks for every `src/modules/configs/agents/` entry except `skills/` |
| `~/.agents/skills/`                   | `agentsSkills` activation                        | Real directory; per-skill symlinks for bundled skills + real dirs for fetched skills               |
| `~/.agents/skills/<name>/` (symlink)  | `agentsSkills`                                   | Bundled skill committed to `src/modules/configs/agents/skills/<name>/`                             |
| `~/.agents/skills/<name>/` (real dir) | `syncClawHubSkills` / `Sync-AgentsClawHubSkills` | Fetched skill downloaded by ClawHub; contains a `.clawhub/origin.json` marker                      |

The per-subdir layout replaces an older whole-dir symlink scheme. The old scheme forced every clawhub download into the tracked repo tree; the real-dir layout lets the `skills/` subtree be writable without any writes entering Git.

## Bundled vs. fetched skills

**Bundled**: AGPL-compatible license → commit all skill files to `src/modules/configs/agents/skills/<name>/`. The `agentsSkills` activation creates a symlink at `~/.agents/skills/<name>` that points into the store.

**Fetched**: non-AGPL-compatible license → never commit; list the skill slug in `src/modules/configs/agents/clawhub-skills.json` under `"skills"`. The `syncClawHubSkills` activation in `src/modules/agents.nix` runs the fetched skill convergence logic inline, downloading skills at apply time via the ClawHub CLI.

The `.clawhub/origin.json` marker written by ClawHub during install is the **sole** reliable signal that a directory in `~/.agents/skills/` is a fetched download. Stale cleanup must check for this marker before removing any directory; directories without it (bundled symlinks, user content) are never removed.

Conflict guard: if a slug in `clawhub-skills.json` matches a committed-skill symlink already in `~/.agents/skills/`, the activation prints a warning and skips that slug; the operator must resolve the naming conflict before ClawHub can write there.

## Permission locking

Installed skill files are locked read-only after each install or update to prevent accidental modification outside a managed apply run. The lock is cleared before an update so clawhub can overwrite existing files.

**POSIX**: `chmod -R a-w` after install; `chmod -R u+w` before update/cleanup.

**Windows**: `FileAttributes.ReadOnly` set via `Get-ChildItem -Recurse` after install; cleared via the same loop before update/cleanup.

Secret and manifest files written by `Sync-NucleusSecretFile` on Windows use a stricter `$restrictAcl` block (`icacls /inheritance:r /grant:r`) on top of `ReadOnly` to ensure owner-only access.

## ClawHub provisioning

ClawHub is the install vehicle for fetched skills. It is a JS CLI tool absent from nixpkgs, cargo-binstall, WinGet, and Scoop — bun is therefore the only viable install tier.

### POSIX

ClawHub is installed and managed declaratively by the `installBunPackages` Home Manager activation in `src/modules/agents.nix`. The activation:

1. Prepends `~/.bun/bin` to `PATH` for the current session.
2. Guards that `bun` is on `PATH` (provided by `pkgs.bun` via `core.nix`).
3. Maintains a desired-state list (`clawhub` is the only current entry).
4. Installs packages whose binary is absent from `~/.bun/bin`.
5. Removes packages no longer desired (via `bun remove -g`).
6. Persists the managed set to `~/.config/nucleus/bun-packages.json`.

### Windows

ClawHub is managed by `Invoke-BunSetup` in `src/hosts/Windows/modules/Invoke-BunSetup.ps1`, which is called by `apply.ps1` before `Sync-AgentsClawHubSkills`. `Invoke-BunSetup` manages a `$desiredPackages` list (currently `@mariozechner/pi-coding-agent` and `clawhub`) and writes a manifest to `%USERPROFILE%\.config\nucleus\bun-packages.json`. Applied in this order: WinGet DSC → `Invoke-BunSetup` (bun global packages) → `Sync-AgentsSkills` (bundled skill symlinks) → `Sync-AgentsClawHubSkills` (fetched skill downloads).

## Authoring rules

- **No fallback installs in sync functions**: POSIX `syncClawHubSkills` and Windows `Sync-AgentsClawHubSkills` must not install ClawHub themselves. Provisioning belongs to `installBunPackages` / `Invoke-BunSetup`.
- **Stale cleanup scoped to fetched downloads**: only remove directories with a `.clawhub/origin.json` marker; never touch bundled symlinks or unknown directories.
- **Skill sync is best-effort**: log a warning on failure and continue.
- **Desired-package lists sorted alphabetically**: keep `$desiredPackages` and the equivalent list in `installBunPackages` sorted.
