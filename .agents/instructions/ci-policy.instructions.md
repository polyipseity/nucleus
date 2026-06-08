---
description: "Use when modifying ci.yml or adding CI workflow steps. Do not insert new checks/tests into ci.yml."
name: "CI Policy"
applyTo: ".github/workflows/**"
---

- Never insert new checks or tests into `ci.yml`. Route new validation into
  repo checks (`scripts/check.sh`, `scripts/check.ps1`) or repo tests
  (`tests/`).
- This decouples check logic from CI runners so checks work locally too.
