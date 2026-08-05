---
description: "Use when setting up a new repository or unfamiliar workspace. Establishes AGENTS.md as the canonical source of truth, explains the .agents/ customization hierarchy, and maps agent entry points."
name: "Workspace Guidance"
applyTo: "**"
alwaysApply: true
---

Project-level source of truth:

- Every project ships an `AGENTS.md` at the repo root—the single authoritative source for repository shape, architecture, build/test/validate commands, per-file-type authoring rules, commit conventions, and invariants that must be preserved.
- Always read `AGENTS.md` before starting work in an unfamiliar repository. It is intentionally short; detailed rules live in focused `.agents/instructions/` files it links to.

Agent customization hierarchy:

| Path                                     | Purpose                                                                      |
| ---------------------------------------- | ---------------------------------------------------------------------------- |
| `.agents/hooks/*.json`                   | Deterministic lifecycle hooks (VS Code Copilot `PreToolUse`/`PostToolUse` etc.), loaded via `chat.hookFilesLocations` (`~/.agents/hooks`). |
| `.agents/instructions/*.instructions.md` | Narrow, file-type-scoped authoring rules loaded automatically by agents.     |
| `.agents/prompts/*.prompt.md`            | Reusable workflow prompts (e.g., commit-staged, release).                    |
| `.agents/skills/<skill>/`                | Skill bundles (scripts + instructions) for repeatable multi-step operations. |

Keep `AGENTS.md` short and durable. Extract sections exceeding ~30 lines into focused `.agents/instructions/` files with narrow `applyTo` globs and link back from `AGENTS.md`.

Agent entry-point mapping by tool:

| Tool           | Project entry point                                             | User entry point             |
| -------------- | --------------------------------------------------------------- | ---------------------------- |
| GitHub Copilot | `AGENTS.md`                                                     | `~/.agents/instructions/`    |
| OpenCode       | `AGENTS.md` + `opencode.jsonc` → `.agents/instructions/**/*.md` | `~/.agents/instructions/`    |
| Cursor         | `.cursor/rules/` (symlinks to shared `instructions/`)         | `~/.cursor/rules/` (`.mdc` aliases → `~/.agents/instructions/`) |
| Claude Code    | `CLAUDE.md` or `AGENTS.md`                                      | `~/.claude/`                 |
| Aider          | `AGENTS.md`                                                     | `.aider.conf.yml` / env vars |

When a project follows this user's conventions, `AGENTS.md` is the definitive entry point. Tool-specific files (`.cursor/rules/`, `CLAUDE.md`) should defer to `AGENTS.md` rather than duplicate its content.

Instruction file frontmatter structure:

Every `.instructions.md` file must open with valid YAML frontmatter containing `description` (keyword-rich, starting with "Use when"), `name` (short human-readable name), and `applyTo` (narrow glob for applicability). Keep `applyTo` narrow so the instruction is only injected when genuinely relevant. Example:

```yaml
---
description: "Use when authoring YAML files in the src/hosts/Windows/ directory."
name: "Windows DSC Configuration"
applyTo: "src/hosts/Windows/**/*.yml"
---
```

## Related instruction files

- `authoring.instructions.md` — Instructions file authoring conventions, markdown formatting, and document structure.
- `core-behavior.instructions.md` — General agent operating model, communication, and execution patterns.
- `programming-principles.instructions.md` — Coding conventions and architectural standards for workspace code.
