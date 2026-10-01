---
description: "Use when setting up a new repository or unfamiliar workspace. Establishes AGENTS.md as the canonical source of truth, explains the .agents/ customization hierarchy, and maps agent entry points."
name: "Workspace Guidance"
applyTo: "**"
alwaysApply: true
---

Read `AGENTS.md` at the repo root before starting work in an unfamiliar repository. It is the authoritative source for repository shape, architecture, build/test/validate commands, per-file-type authoring rules, commit conventions, and invariants. It is intentionally short; detailed rules live in the `.agents/instructions/` files it links to. Tool-specific files such as `CLAUDE.md` or `.cursor/rules/` defer to it rather than duplicate it.

Keep `AGENTS.md` short and durable. Extract a section longer than about 30 lines into a focused `.agents/instructions/` file with a narrow `applyTo` glob and link back from `AGENTS.md`.

| Path | Purpose |
| --- | --- |
| `.agents/hooks/*.json` | Lifecycle hooks (`PreToolUse`/`PostToolUse` and similar), loaded via `chat.hookFilesLocations` (`~/.agents/hooks`) |
| `.agents/instructions/*.instructions.md` | Narrow, file-type-scoped rules loaded automatically |
| `.agents/prompts/*.prompt.md` | Reusable workflow prompts |
| `.agents/skills/<skill>/` | Skill bundles (scripts plus instructions) |

| Tool | Project entry point | User entry point |
| --- | --- | --- |
| GitHub Copilot | `AGENTS.md` | `~/.agents/instructions/` |
| OpenCode | `AGENTS.md` plus `opencode.jsonc` registering `.agents/instructions/**/*.md` | `~/.agents/instructions/` |
| Cursor | `.cursor/rules/`, symlinked to shared instructions | `~/.cursor/rules/`, `.mdc` aliases |
| Claude Code | `CLAUDE.md` or `AGENTS.md` | `~/.claude/` |
| Aider | `AGENTS.md` | `.aider.conf.yml` or env vars |

Every `.instructions.md` opens with valid YAML frontmatter holding `description` (keyword-rich, starting with "Use when"), `name` (short human-readable name), and `applyTo` (a narrow glob, so the instruction loads only where it is relevant):

```yaml
---
description: "Use when authoring YAML files in the src/hosts/Windows/ directory."
name: "Windows DSC Configuration"
applyTo: "src/hosts/Windows/**/*.yml"
---
```
