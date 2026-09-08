---
description: "Use when authoring or reviewing hard-coded denylists and allowlists. Canonical registry; policy: eliminate (T1), self-prune (T2), or track (T3). Review quarterly."
name: "Allow and Deny List Policy"
applyTo: "scripts/**, src/**, tests/**"
---

# Allow and deny list policy

This file is the canonical registry of all hard-coded filter lists in this repository, covering both:

- **Denylists** (exclusions): files, directories, or content patterns that are intentionally skipped by checks or automation.
- **Allowlists** (exceptions): entries that are intentionally permitted despite matching a deny rule or validation criterion.

Every hard-coded filter — whether positive (allow) or negative (deny) — must be registered here with its category, justification, and tier.

## Tiers

1. **Tier 1 (Eliminate).** Remove the exclusion entirely — replace with dynamic discovery, or remove if the exclusion is no longer needed.
2. **Tier 2 (Self-prune, must error).** If exclusion cannot be eliminated, add a verification step after the main check: verify that each excluded file still justifies its exclusion (either the file still exists, or still contains the pattern that triggered the exclusion). If stale, **must error** — a warning that does not fail the build is not acceptable.
3. **Tier 3 (Track).** If neither Tier 1 nor Tier 2 works, register below with inline `# ref: allow-and-deny-lists.instructions.md` comments at every exclusion site. All Tier 3 entries must be reviewed quarterly.

## Inline comment convention

Every hard-coded filename exclusion site gets a suffix comment:

```sh
--exclude='check.sh'  # ref: allow-and-deny-lists.instructions.md#A1 -- orchestrator contains pip/npm patterns in comments; would cause false positives
```

Comments MUST use the canonical grammar `# ref: <target> -- <just>` and include:

- The reference to the policy section as `<target>` (`#A1`, `#A2`, etc.)
- A brief reason as `<just>` why the exclusion cannot be (or was not) eliminated
- The `--` separator (never an em dash), with no `reason:` keyword

## Gitignore-based denylist

The repository uses `git check-ignore --stdin` as a batch-mode gitignore-aware
filter, provided by a shared library:

- **`src/scripts/lib/deny-list.sh`** (POSIX) — `filter_gitignored` (stdin filter),
  `find_git_tracked` (find wrapper)
- **`src/scripts/lib/deny-list.ps1`** (PowerShell) — `Select-GitIgnored` (pipeline
  filter), `Get-GitTrackedFile`

### Policy

1. **All check/test scripts that generate file lists must pipe through
   `filter_gitignored`/`Select-GitIgnored` by default.** The `cache_file_lists()`
   function in `step-runner.sh`/`step-runner.ps1` applies this to all cached file
   lists (`CACHED_NIX_FILES`, `CACHED_YAML_FILES`, `CACHED_JSON_FILES`,
   `CACHED_SHELL_FILES`).
2. **Hard-coded exclusions in check scripts must only exist for reasons that are
   NOT about gitignore semantics** — e.g., excluding `check.sh` from a grep
   because it contains the pattern being searched for. If the exclusion duplicates
   a `.gitignore` entry, remove it.
3. **Structural directory exclusions** (e.g., `vendor/` for performance) are
   retained as find `-prune` patterns, with `filter_gitignored` applied on top.
   These are registered in Category B with the note "supplemented by gitignore."
4. **`git` is a hard requirement** for all check scripts that use
   `filter_gitignored`. Missing `git` produces a startup error via
   `preflight_check()`.

### API

```sh
# POSIX — reads paths from stdin, writes non-ignored paths to stdout
filter_gitignored

# POSIX — wraps find, excludes gitignored files
find_git_tracked [find_args...]
```

```powershell
# PowerShell — pipeline filter, same semantics
Get-ChildItem ... | Select-GitIgnored
```

### Integration points

| Layer | Integration |
| ------------------------ | -------------------------------------------------------------------------------------------------------- |
| `step-runner.sh`/`.ps1` | Sources deny-list library; `require_command git` in preflight; `cache_file_lists()` pipes through filter |
| Check steps (POSIX) | Steps 11, 14 use `filter_gitignored` |
| Check steps (PowerShell) | Steps 7, 9, 14 use `Select-GitIgnored` |
| `test-lib.sh` | Sources deny-list library; test file discovery pipes through filter |

## Instance registry

Full per-file exclusion registry (Categories A–D), dummy key management rules, and verification details are in `allow-deny-instance-registry.reference.md`.

When adding new exclusions: register with the correct category ID, tier, and inline `# ref:` comment. Review quarterly.

## Review cadence

- **Quarterly**: full audit of all T3 entries. Check each excluded file still exists, each excluded pattern is still justified, and no new hard-coded exclude lists have been introduced. Verify that gitignore-based filtering (via `filter_gitignored`/`Select-GitIgnored`) is applied to any new file-generation script.
- **Quarterly — shared-content audit**: for each content category in the embedded-content policy (profile body, VM start scripts, service wrappers, Caddyfile, cloud-drive wrappers), confirm there is exactly ONE canonical file on disk and no same-language duplicate has re-appeared (e.g. a second inline copy of the Android VM QEMU start script). Step 14's embedded-content enforcement sub-check (repository-policy) flags new large embedded literals; any duplicate found here is fixed in the same review. Registry of shared files lives in `embedded-content.instructions.md` § Shared cross-platform content.
- **Trigger**: review is due when a check step is added, removed, or renumbered.
- **Last reviewed**: 2026-08-13 (14 check steps; numbers derived from NN- filename prefixes)
- **Verification**: run `scripts/check.sh` (which includes step 14 `repository-policy` for preflight InstallCommand policy) to catch regressions.
