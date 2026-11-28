---
description: "Use when editing infrastructure code, data files, or MANUAL.md."
name: "Documentation Standards"
applyTo: "src/**/*.nix, src/**/*.ps1, src/**/*.json, src/**/*.jsonc, src/**/*.yaml, src/**/*.yml, src/hosts/Windows/**/*.yml, src/hosts/**/MANUAL.md, scripts/**, src/scripts/**"
alwaysApply: true
---

# Documentation standards

Document WHY with `# WHY: <reason>`; no backwards compatibility and no em dash in repo prose. Avoid additionally, crucial, pivotal, robust, seamless, comprehensive, delve, showcase, leverage, in order to, and it is important to note. Check for line-pinned tests with `grep -rl '<file>' tests/` before editing text. Delete wrong or stale comments and docs, never move a shebang, and name the source of truth instead of mirroring code paths or fields.

Sentence-case user-facing labels; YAML uses `.yml` except required `.sops.yaml`. Deterministic JSON is byte-stable: case-sensitive sorted keys, sorted set arrays, one trailing newline, 2-space indent, compact empty objects and arrays, via `toSortedJSON` or `ConvertTo-SortedJson`. `.instructions.md` and `.prompt.md` need valid frontmatter; edit `commit-staged.prompt.md` in both locations together; never add `.github/copilot-instructions.md`.

Per-file comment, MANUAL, markdown, and citation rules: `src/users/default/agents/skills/nucleus-citation-reference/references/documentation.md`; source rules: `citation-quality.md` in the same skill.
