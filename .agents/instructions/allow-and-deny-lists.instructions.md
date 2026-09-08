---
description: "Use when authoring or reviewing hard-coded denylists and allowlists. Canonical registry; policy: eliminate (T1), self-prune (T2), or track (T3). Review quarterly."
name: "Allow and Deny List Policy"
applyTo: "scripts/**, src/**, tests/**"
---

# Allow and deny list policy

Registry of all hard-coded filter lists. Every filter: category, justification, tier.

## Tiers

1. **T1 (Eliminate).** Remove or replace with dynamic discovery.
2. **T2 (Self-prune, must error).** Post-check: confirm each exclusion still holds. Stale → error.
3. **T3 (Track).** `# ref: allow-and-deny-lists.instructions.md` at site. Quarterly review.

## Inline comment

`# ref: <target> -- <just>` — e.g. `# ref: allow-and-deny-lists.instructions.md#A1 -- pip/npm in comments`. `--` separator, never em dash. No `reason:` keyword.

## Gitignore-based denylist

Library: `src/scripts/lib/deny-list.sh` (`filter_gitignored`, `find_git_tracked`), `deny-list.ps1` (`Select-GitIgnored`, `Get-GitTrackedFile`).

1. File lists pipe through `filter_gitignored`/`Select-GitIgnored` (automatic via `cache_file_lists()`).
2. Hard-coded exclusions only for non-gitignore reasons. Remove `.gitignore`-duplicates.
3. Structural dir exclusions (e.g. `vendor/`) as find `-prune` + filter → Category B.
4. `git` required — missing fails `preflight_check()`.

| Layer | Usage |
| --- | --- |
| `step-runner` | Sources lib; `require_command git`; `cache_file_lists()` pipes |
| Check steps | POSIX: 11, 14; PowerShell: 7, 9, 14 |
| `test-lib.sh` | Discovery pipes through filter |

## Instance registry

Categories A–D, dummy key rules: `allow-deny-instance-registry.reference.md`. New exclusions: category ID, tier, `# ref:`.

## Review

- **Quarterly**: audit T3 — files exist, patterns justified, no new hard-coded excludes.
- **Shared-content**: per `embedded-content.instructions.md` § Shared cross-platform content. Step 14 flags duplicates.
- **Trigger**: check step added/removed/renumbered. **Last reviewed**: 2026-08-13.
