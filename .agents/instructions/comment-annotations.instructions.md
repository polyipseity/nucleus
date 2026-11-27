---
description: "Use when authoring or editing code comment annotations in this repo."
name: "Comment Annotations"
applyTo: "scripts/**, src/**, tests/**"
---

# Comment annotations

Grammar: `# <prefix>: <reason>` or `# <prefix>: <subject> -- <reason>`; `--` is the only separator, never an em dash. Categories 1 and 2 are machine-parsed, categories 3 and 4 are human-readable. `# WHY:` explains decisions, `# ref:` cites policy, source, or dependency, `# TODO:` records work; DSC YAML uses `# ref:` only.

Tool-enforced ids and consumers: `suppression_doc` (step 11), `SuppressMessageAttribute` (step 11), `packer_validate` (`check.*`), `embedded-content` (step 13), `config-method` (step 12). `|| true`, `$null =`, `[void]`, `2>$null`, and `-ErrorAction SilentlyContinue` need `# check-suppress:suppression_doc:` in production code (tests exempt), not `# WHY:`. A new marker needs its id and machine consumer registered before use. Review-only violations are listed in the reference.

Full grammar, tables, and enforcement: `.agents/skills/nucleus-citation-reference/references/comment-annotations.md`.
