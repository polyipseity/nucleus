---
description: "Use when authoring or reviewing hard-coded denylists and allowlists."
name: "Allow and Deny List Policy"
applyTo: "scripts/**, src/**, tests/**"
---

# Allow and deny list policy

Every hard-coded filter list carries a category id, a justification, and a tier. The full instance registry, with IDs A2 through E1, tiers, reasons, and verification, is in `src/users/default/agents/skills/nucleus-policy-reference/references/allow-and-deny-lists.md`.

Tiers: T1 eliminate or replace with dynamic discovery; T2 self-prune with an error on stale entries; T3 track with `# ref: allow-and-deny-lists.instructions.md` at the site and quarterly review.

## Gitignore-based denylist

`src/scripts/lib/deny-list.sh` provides `filter_gitignored` and `find_git_tracked`; `deny-list.ps1` provides `Select-GitIgnored` and `Get-GitTrackedFile`. File lists pipe through the filter: `step-runner.sh` does this in `cache_file_lists()`; POSIX check steps 11, 12, 13 and PowerShell steps 07, 11, 12, 13 call it directly. Hard-coded exclusions are only for non-gitignore reasons; drop duplicates of `.gitignore`. Structural directory exclusions such as `vendor/` use find `-prune` plus the filter (Category B). `git` is required; a missing one fails `require_command` in step-runner preflight.

A new exclusion needs a category id, tier, and `# ref:`. Tier 2 entries must error when stale.

## Dummy keys

`src/modules/dummy-keys.json` is validated against `src/modules/dummy-keys.schema.json`. An `sk-` placeholder of 4 or more alphanumerics resolves to `dummyKeys.<name>.value`; consumers use that value verbatim, and every entry carries `value`, `consumers`, and `note`. Step 13 `run_dummy_key_uniformity` enforces it.

## Review

Quarterly audit of T3 rows: files exist, patterns justified, no new hard-coded excludes. Re-review when a check step is added, removed, or renumbered. Last reviewed 2026-09-30.
