---
description: "Use when authoring or reviewing hard-coded denylists and allowlists. Canonical registry; policy: eliminate (T1), self-prune (T2), or track (T3). Review quarterly."
name: "Allow and Deny List Policy"
applyTo: "scripts/**, src/**, tests/**"
---

# Allow and deny list policy

Registry of all hard-coded filter lists — denylists (exclusions) and allowlists (exceptions). Every filter registered here with category, justification, and tier.

## Tiers

1. **T1 (Eliminate).** Remove — replace with dynamic discovery or drop if unused.
2. **T2 (Self-prune, must error).** Post-check verification: confirm each exclusion still holds. Stale entries must error.
3. **T3 (Track).** Register with `# ref: allow-and-deny-lists.instructions.md` at every exclusion site. Quarterly review.

## Inline comment convention

Format: `# ref: <target> -- <just>` — e.g. `# ref: allow-and-deny-lists.instructions.md#A1 -- orchestrator contains pip/npm patterns`. Target = `#A1` etc. Separator `--` (never em dash). No `reason:` keyword.

## Gitignore-based denylist

Shared library: `git check-ignore --stdin` batch filtering.

- `src/scripts/lib/deny-list.sh` — `filter_gitignored` (stdin), `find_git_tracked` (find wrapper)
- `src/scripts/lib/deny-list.ps1` — `Select-GitIgnored` (pipeline), `Get-GitTrackedFile`

### Policy

1. Check/test scripts pipe file lists through `filter_gitignored`/`Select-GitIgnored`. `cache_file_lists()` in `step-runner.sh`/`.ps1` does this automatically.
2. Hard-coded exclusions only for reasons outside gitignore (e.g. self-referencing grep). Remove exclusions duplicating `.gitignore` entries.
3. Structural directory exclusions (e.g. `vendor/`) retained as find `-prune` patterns, with `filter_gitignored` on top — register in Category B.
4. `git` is required — missing `git` fails `preflight_check()`.

### API

| POSIX | PowerShell |
| --- | --- |
| `filter_gitignored` (stdin filter) | `Select-GitIgnored` (pipeline) |
| `find_git_tracked [args...]` (find wrapper) | `Get-GitTrackedFile` |

### Integration

| Layer | Usage |
| --- | --- |
| `step-runner.sh`/`.ps1` | Sources lib; `require_command git` preflight; `cache_file_lists()` pipes |
| Check steps | POSIX: 11, 14; PowerShell: 7, 9, 14 |
| `test-lib.sh` | Test file discovery pipes through filter |

## Instance registry

Categories A–D, dummy key rules, verification: `allow-deny-instance-registry.reference.md`. New exclusions: register with category ID, tier, `# ref:` comment.

## Review cadence

- **Quarterly**: audit all T3 — confirm files exist, patterns justified, no new hard-coded excludes. Verify `filter_gitignored` on any new file-generation script.
- **Quarterly — shared-content**: per `embedded-content.instructions.md` § Shared cross-platform content, one canonical file per category. Step 14 flags new embedded literals; fix duplicates same review.
- **Trigger**: check step added, removed, or renumbered.
- **Last reviewed**: 2026-08-13 (14 check steps; NN- prefixes)
- **Verification**: `scripts/check.sh` step 14 `repository-policy`.
