---
description: "Canonical registry of all hard-coded denylists and allowlists. Policy: eliminate (T1), self-prune (T2), or track (T3). Review quarterly."
name: "Allow and Deny List Policy"
applyTo: "**"
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
--exclude='check.sh'  # ref: allow-and-deny-lists.instructions.md#A1 — reason: orchestrator contains pip/npm patterns in comments; would cause false positives
```

Comments MUST include:

- The reference to the policy section (`#A1`, `#A2`, etc.)
- A brief reason why the exclusion cannot be (or was not) eliminated

## Gitignore-based denylist

The repository uses `git check-ignore --stdin` as a batch-mode gitignore-aware
filter, provided by a shared library:

- **`src/scripts/lib/deny-list.sh`** (POSIX) — `filter_gitignored` (stdin filter),
  `find_git_tracked` (find wrapper)
- **`src/scripts/lib/deny-list.ps1`** (PowerShell) — `Filter-GitIgnored` (pipeline
  filter), `Get-GitTrackedFile`

### Policy

1. **All check/test scripts that generate file lists must pipe through
   `filter_gitignored`/`Filter-GitIgnored` by default.** The `cache_file_lists()`
   function in `step-runner.sh`/`step-runner.ps1` applies this to all cached file
   lists (`CACHED_NIX_FILES`, `CACHED_YAML_FILES`, `CACHED_JSON_FILES`,
   `CACHED_SH_FILES`).
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
Get-ChildItem ... | Filter-GitIgnored
```

### Integration points

| Layer | Integration |
|---|---|
| `step-runner.sh`/`.ps1` | Sources deny-list library; `require_command git` in preflight; `cache_file_lists()` pipes through filter |
| Check steps (POSIX) | Steps 13, 15, 16, 19, 21 use `filter_gitignored` |
| Check steps (PowerShell) | Steps 13, 15, 19, 21 use `Filter-GitIgnored` |
| `test-lib.sh` | Sources deny-list library; test file discovery pipes through filter |

## Instance registry

### Category A — Filename-based exclude lists

| ID  | Files                                       | Excluded                                              | Tier | Reason                                                                                                                                                       | Verification                                                       |
| --- | ------------------------------------------- | ----------------------------------------------------- | ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------ |
| A1  | `16-package-manager-enforcement.sh`, `.ps1` | `check.sh`, `check.ps1`, `shell.nix` (+ self-refs)    | T2   | Orchestrator/parent config files legitimately contain `pip`/`npm` in comments and error messages; self-refs are dynamic                                      | grep after each run: excluded files still contain pip/npm patterns |
| A2  | `19-config-method-compliance.sh`, `.ps1`    | `.gitkeep`, `.gitignore`, `*.schema.json`, `agents/*` | T3   | Infrastructure files are not configs; `agents/*` consumed as directory. Note: `qtpass.nix` removed 2026-07-29 by self-pruning check — file no longer existed | Manual quarterly review                                            |
| A3  | `12-locked-dsc-validation.ps1`              | `packages.dsc.yml`                                    | T2   | Packages DSC is generated from lockfile, not manually authored                                                                                               | Verify file still exists                                           |
| A5  | `gc.sh`, `gc.ps1`                           | `index.lock`                                          | T3   | Git invariant — `index.lock` must never be cleaned                                                                                                           | Manual quarterly review                                            |
| A6  | `test-lib.sh`                               | `lib.nix` in test discovery                           | T2   | Test helper library excluded from namespace of test files                                                                                                    | Verify file still exists                                           |
| A7  | `step-runner.sh`, `step-runner.ps1`         | `*.schema.json`                                       | T3   | Glob pattern for schema files is narrow and stable                                                                                                           | Manual quarterly review                                            |

### Category B — Directory-based exclude lists

| ID  | Files                                     | Excluded dirs         | Tier | Reason                                                                          | Verification            |
| --- | ----------------------------------------- | --------------------- | ---- | ------------------------------------------------------------------------------- | ----------------------- |
| B1  | `19-config-method-compliance.sh`, `.ps1`  | `vendor/`, `configs/` | T3   | Structural invariants — vendored code and config methods are different concerns | Manual quarterly review |
| B2  | `01-code-formatting.ps1`                  | `vendor/`             | T3   | Structural invariant (vendor/ speed); secrets/ covered by gitignore (treefmt natively respects .gitignore) | Manual quarterly review |
| B3  | `13-schema-validation.ps1`                | `vendor/`             | T3   | Structural invariant (vendor/ speed); secrets/ dropped — covered by gitignore + Filter-GitIgnored | Manual quarterly review |
| B4  | `15-yaml-structural.ps1`                  | `vendor/`             | T3   | Structural invariant (vendor/ speed); secrets/ dropped — covered by gitignore + Filter-GitIgnored | Manual quarterly review |
| B5  | `17-suppression-audit.ps1`                | `vendor/`             | T3   | Structural invariant; supplemented by Filter-GitIgnored                        | Manual quarterly review |
| B6  | `21-preflight-install-command-policy.ps1` | `vendor/`             | T3   | Structural invariant; supplemented by Filter-GitIgnored                        | Manual quarterly review |
| B7  | `step-runner.sh`, `step-runner.ps1`       | `vendor/`             | T3   | Structural invariant; supplemented by filter_gitignored/Filter-GitIgnored       | Manual quarterly review |
| B8  | `cleanup-nix-build-artifacts.sh`          | `vendor/`             | T3   | Structural invariant                                                            | Manual quarterly review |

### Category C — Content-pattern exclude lists (grep -v, notmatch)

| ID  | Files                        | Excluded pattern                         | Tier | Reason                                                | Verification            |
| --- | ---------------------------- | ---------------------------------------- | ---- | ----------------------------------------------------- | ----------------------- |
| C1  | `script-validation-tests.sh` | `HOME\|TMPDIR\|/tmp\|--` in rm -rf check | T3   | Known-safe patterns in test; false-positive reduction | Manual quarterly review |
| C2  | `script-validation-tests.sh` | `^svc: warning:` in service test         | T3   | Runtime warning noise from svc script                 | Manual quarterly review |
| C3  | `apple-sdk-override.sh`      | env vars in nix output filter            | T3   | Nix-env debug output suppression                      | Manual quarterly review |

### Category D — Allowlists

| ID  | Files                                    | Allowed entry                         | Tier | Reason                                                                | Verification                    |
| --- | ---------------------------------------- | ------------------------------------- | ---- | --------------------------------------------------------------------- | ------------------------------- |
| D1  | `11-lockfile-validation.ps1`             | `lfOverlapExceptions`: `astral-sh.ty` | T2   | Legitimate cross-section overlap in lockfile                          | Error if stale                  |
| D2  | `lifecycle-allowlist.json`               | All entries                           | T2   | Supply-chain hardening: lifecycle hooks permitted for listed packages | Error if stale (via `check.sh`) |
| D3  | `supply-chain-hardening.instructions.md` | Allowlist mechanism (cross-reference) | —    | External allowlist maintained in supply-chain-hardening docs          | See that file                   |

## Review cadence

- **Quarterly**: full audit of all T3 entries. Check each excluded file still exists, each excluded pattern is still justified, and no new hard-coded exclude lists have been introduced. Verify that gitignore-based filtering (via `filter_gitignored`/`Filter-GitIgnored`) is applied to any new file-generation script.
- **Trigger**: review is due when a check step is added, removed, or renumbered.
- **Last reviewed**: 2026-07-30 (gitignore-based denylist section added; T3 entries confirmed valid with gitignore filter supplement notes)
- **Verification**: run `scripts/check.sh` (which includes step 21 for preflight policy) to catch regressions.
