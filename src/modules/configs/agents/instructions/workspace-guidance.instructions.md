---
description: "User-level baseline guidance. Establishes AGENTS.md as the canonical project source of truth, explains the .agents/ customization hierarchy, and maps each AI coding agent to the correct entry-point files."
name: "Workspace Guidance"
applyTo: "**"
---

# Workspace Guidance

## Project-level source of truth

Every project in this user's workflow ships an `AGENTS.md` at the repo root.
It is the single authoritative source for:

- Repository shape, architecture, and build/test/validate commands.
- Per-file-type authoring rules (linked to focused `.agents/instructions/` files).
- Commit and PR conventions.
- Invariants that must be preserved across changes.

**Always read `AGENTS.md` before starting work in any unfamiliar repository.**
It is intentionally short; detailed rules live in focused instruction files that
it links to.

## Agent customization hierarchy

Each repository may contain a `.agents/` directory with three asset types:

| Path | Purpose |
|---|---|
| `.agents/instructions/*.instructions.md` | Narrow, file-type-scoped authoring rules loaded automatically by agents that support instruction files. |
| `.agents/prompts/*.prompt.md` | Reusable workflow prompts (e.g. commit-staged, release). |
| `.agents/skills/<skill>/` | Skill bundles (scripts + instructions) for repeatable multi-step operations. |

Keep `AGENTS.md` short and durable.  When any section grows beyond a few
bullet points, extract it into a focused `.agents/instructions/` file with a
narrow `applyTo` glob and link back from `AGENTS.md`.

## Agent entry-point mapping

Different tools use different file names to discover project context:

| Tool | Project entry point | User entry point |
|---|---|---|
| GitHub Copilot | `AGENTS.md` | `~/.agents/instructions/` |
| OpenCode | `AGENTS.md` + `opencode.jsonc` → `.agents/instructions/**/*.md` | `~/.agents/instructions/` |
| Cursor | `.cursor/rules/` | `~/.cursor/rules/` |
| Claude Code | `CLAUDE.md` or `AGENTS.md` | `~/.claude/` |
| Aider | `AGENTS.md` | `.aider.conf.yml` / env vars |

When a project follows this user's conventions, `AGENTS.md` is the definitive
entry point.  Tool-specific files (`.cursor/rules/`, `CLAUDE.md`) should defer
to `AGENTS.md` rather than duplicate its content.

## When to split `AGENTS.md`

Extract into `.agents/instructions/<topic>.instructions.md` when any of the
following conditions holds:

- A section exceeds ~30 lines.
- A rule applies only to specific file types or directories (use a narrow
  `applyTo` glob).
- A rule is reusable across multiple repositories and should travel with the
  user rather than remain project-scoped.

## Instruction file frontmatter

Every `.instructions.md` file must open with valid YAML frontmatter:

```yaml
---
description: "Use when ... (keyword-rich, starting with 'Use when')"
name: "Short Human-Readable Name"
applyTo: "src/**/*.nix, src/**/*.ps1"   # narrow glob; use ** only if truly global
---
```

Keep `applyTo` as narrow as practical so the instruction is only injected when
it is genuinely relevant.
