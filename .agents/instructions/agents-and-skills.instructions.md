---
description: "Use when adding or editing agents configuration, skill management, or clawhub provisioning. Covers ~/.agents directory layout, bundled vs. fetched skill licensing rules, permission patterns, and the installBunPackages/syncClawhubSkills activation DAG."
name: "Agents and Skills"
applyTo: "src/modules/agents.nix, src/modules/windows/sync-agentsskills.ps1, src/modules/windows/sync-agentsclawhubskills.ps1, src/modules/windows/bun-setup.ps1, src/modules/configs/agents/**"
---

# Agents and Skills

## Directory layout

The `~/.agents/` directory is the runtime home for all agent configuration,
prompts, and skills.  It is a real (writable) directory, **not** a whole-dir
symlink into the repo tree.

| Path | Owner | Purpose |
|---|---|---|
| `~/.agents/` | `agentsSymlink` activation | Real directory; per-subdir symlinks for every `src/modules/configs/agents/` entry except `skills/` |
| `~/.agents/skills/` | `agentsSkills` activation | Real directory; per-skill symlinks for bundled skills + real dirs for fetched skills |
| `~/.agents/skills/<name>/` (symlink) | `agentsSkills` | Bundled skill committed to `src/modules/configs/agents/skills/<name>/` |
| `~/.agents/skills/<name>/` (real dir) | `syncClawhubSkills` / `Sync-AgentsClawhubSkills` | Fetched skill downloaded by clawhub; contains a `.clawhub/origin.json` marker |

The per-subdir layout replaces an older whole-dir symlink scheme.  The old
scheme forced every clawhub download into the tracked repo tree; the real-dir
layout lets the `skills/` subtree be writable without any writes entering Git.

## Bundled vs. fetched skills

**Bundled**: AGPL-compatible license → commit all skill files to
`src/modules/configs/agents/skills/<name>/`.  The `agentsSkills` activation
creates a symlink at `~/.agents/skills/<name>` that points into the store.

**Fetched**: non-AGPL-compatible license → never commit; list the skill slug in
`src/modules/configs/agents/clawhub-skills.json` under `"skills"`.  The
`syncClawhubSkills` activation in `src/modules/agents.nix` runs the fetched
skill convergence logic inline, downloading skills at apply time via the
clawhub CLI.

The `.clawhub/origin.json` marker written by clawhub during install is the
**sole** reliable signal that a directory in `~/.agents/skills/` is a fetched
download.  Stale cleanup must check for this marker before removing any
directory; directories without it (bundled symlinks, user content) are never
removed.

Conflict guard: if a slug in `clawhub-skills.json` matches a committed-skill
symlink already in `~/.agents/skills/`, the activation prints a warning and
skips that slug; the operator must resolve the naming conflict before clawhub
can write there.

## Permission locking

Installed skill files are locked read-only after each install or update to
prevent accidental modification outside a managed apply run.  The lock is
cleared before an update so clawhub can overwrite existing files.

**POSIX**: `chmod -R a-w` after install; `chmod -R u+w` before update/cleanup.

**Windows**: `FileAttributes.ReadOnly` set via `Get-ChildItem -Recurse` after
install; cleared via the same loop before update/cleanup.

Secret and manifest files written by `Sync-NucleusSecretFile` on Windows use a
stricter `$restrictAcl` block (`icacls /inheritance:r /grant:r`) on top of
`ReadOnly` to ensure owner-only access.

## Clawhub provisioning

Clawhub is the install vehicle for fetched skills.  It is a JS CLI tool absent
from nixpkgs, cargo-binstall, WinGet, and Scoop — bun is therefore the only
viable install tier.

### POSIX

Clawhub is installed and managed declaratively by the `installBunPackages`
Home Manager activation in `src/modules/agents.nix`.  The activation:

1. Prepends `~/.bun/bin` to `PATH` for the current session.
2. Guards that `bun` is on `PATH` (provided by `pkgs.bun` via `core.nix`).
3. Maintains a desired-state list (`clawhub` is the only current entry).
4. Installs packages whose binary is absent from `~/.bun/bin`.
5. Removes packages no longer desired (via `bun remove -g`).
6. Persists the managed set to `~/.config/nucleus/bun-packages.json`.

**Do not add a fallback `bun install -g clawhub` call inside** the
`syncClawhubSkills` activation logic.  If clawhub is absent when sync runs,
the `installBunPackages` activation failed; sync must warn and skip rather
than attempt a second install.

### Windows

Clawhub is managed by `Invoke-BunSetup` in
`src/modules/windows/bun-setup.ps1`, which is called by `apply.ps1` before
`Sync-AgentsClawhubSkills`.  `Invoke-BunSetup` manages a
`$desiredPackages` list (currently `@mariozechner/pi-coding-agent` and
`clawhub`) and writes a manifest to
`%USERPROFILE%\.config\nucleus\bun-packages.json`.

**Do not add a fallback `bun install -g clawhub` call inside**
`Sync-AgentsClawhubSkills`.  If clawhub is absent when the function runs,
`Invoke-BunSetup` failed; the function must warn and skip.

## Activation DAG (POSIX)

```
linkGeneration
  └─ agentsSymlink      (creates real ~/.agents/; per-subdir symlinks)
       └─ agentsSkills  (creates real ~/.agents/skills/; bundled skill symlinks)
            └─ installBunPackages  (installs bun global packages incl. clawhub)
                 └─ syncClawhubSkills  (inline fetched skill convergence)
                      └─ displayHostManualInstructions  (terminal node)
```

Both `installBunPackages` and `syncClawhubSkills` must be added to:
- `displayHostManualInstructionDeps` in `src/modules/macos.nix`
- `entryAfter` list of `displayHostManualInstructions` in `src/modules/linux.nix`

When a new `home.activation` entry is added to `agents.nix`, update the deps
list in **both** `macos.nix` and `linux.nix` in the same change.

## Windows apply order

```
WinGet DSC (system.dsc.yml)
  → Invoke-BunSetup        (bun global packages incl. clawhub)
  → Sync-AgentsSkills      (bundled skill symlinks)
  → Sync-AgentsClawhubSkills  (fetched skill downloads)
```

## Key files

| File | Purpose |
|---|---|
| `src/modules/agents.nix` | POSIX activation DAG: `agentsSymlink`, `agentsSkills`, `installBunPackages`, `syncClawhubSkills` |
| `src/modules/macos.nix` | `displayHostManualInstructionDeps` must include all activation names |
| `src/modules/linux.nix` | `displayHostManualInstructions` `entryAfter` must include all activation names |
| `src/hosts/windows/apply.ps1` | Windows orchestrator; displays `MANUAL.md` as the final step after all convergence |
| `src/modules/configs/agents/clawhub-skills.json` | Declarative fetched skill manifest (`{"skills":[...slugs...]}`) |
| `src/modules/configs/agents/skills/` | Bundled (committed, AGPL-compatible) skill directories |
| `src/modules/windows/bun-setup.ps1` | Windows bun global package manager; includes clawhub |
| `src/modules/windows/sync-agentsskills.ps1` | Windows bundled skill sync |
| `src/modules/windows/sync-agentsclawhubskills.ps1` | Windows fetched skill sync; expects clawhub pre-installed by `Invoke-BunSetup` |
| `src/hosts/windows/apply.ps1` | Windows orchestrator; calls `Invoke-BunSetup` before `Sync-AgentsClawhubSkills` |

## Authoring rules

- **No fallback installs in sync functions**: the POSIX `syncClawhubSkills`
  activation logic and Windows `Sync-AgentsClawhubSkills` helper must not
  attempt to install clawhub themselves.
  Provisioning belongs to `installBunPackages` (POSIX) / `Invoke-BunSetup` (Windows).
- **Stale cleanup scoped to fetched downloads**: only remove directories that
  carry a `.clawhub/origin.json` marker; never touch bundled symlinks or unknown
  directories.
- **Skill sync is best-effort**: a failed sync does not break the activated
  system.  Print a warning and continue so `displayHostManualInstructions` is
  always reached.
- **Desired-package list sorted alphabetically**: keep `$desiredPackages` in
  `bun-setup.ps1` and the equivalent list in `installBunPackages` sorted.
