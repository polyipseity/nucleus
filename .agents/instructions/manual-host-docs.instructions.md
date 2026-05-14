---
description: "Use when editing host MANUAL.md files under src/hosts/. Keep manuals minimal, practical, and focused on only the non-automatable steps users must do."
name: "Host MANUAL Minimalism"
applyTo: "src/hosts/**/MANUAL.md"
---

# Host MANUAL Minimalism

## Purpose

- `MANUAL.md` files are concise checklists shown after apply.
- They must include only steps that are genuinely manual and cannot be safely automated.

## Content rules

- Keep formatting minimal: one title plus short bullet lists.
- Keep text minimal and high signal; remove long explanations, background essays, and full alias reference tables.
- Include a minimal shell-alias list with short descriptions in bullets (no markdown tables).
- Prefer direct actions with concrete command/file names in backticks.
- Prefer one step per bullet.
- If a setup command exists (for example `nucleus-cloud-setup`), point to that command instead of expanding internal implementation details.

## Scope rules

- Do not duplicate declarative behavior that `apply` already guarantees.
- Keep host-specific exceptions only (for example unsupported providers or platform permission prompts).
- If a step becomes automatable later, remove it from `MANUAL.md` in the same change.
