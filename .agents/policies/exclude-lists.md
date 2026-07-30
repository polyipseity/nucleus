---
description: "Canonical registry of all hard-coded exclude/filter lists. Policy: eliminate (T1), self-prune (T2), or track (T3). Review quarterly."
name: "Exclude List Policy"
applyTo: "**"
---

# Exclude list policy

## Tiers

1. **Tier 1 (Eliminate).** Remove the exclusion entirely — replace with dynamic discovery, or remove if the exclusion is no longer needed.
2. **Tier 2 (Self-prune).** If exclusion cannot be eliminated, add a verification step after the main check: verify that each excluded file still justifies its exclusion (either the file still exists, or still contains the pattern that triggered the exclusion). If stale, error out.
3. **Tier 3 (Track).** If neither Tier 1 nor Tier 2 works, register below with inline `# ref: EXCLUDE-LISTS.md` comments at every exclusion site. All Tier 3 entries must be reviewed quarterly.

## Inline comment convention

Every hard-coded filename exclusion site gets a suffix comment:

```sh
--exclude='check.sh'  # ref: EXCLUDE-LISTS.md#A1 — reason: orchestrator contains pip/npm patterns in comments; would cause false positives
```

Comments MUST include:
- The reference to the policy section (`#A1`, `#A2`, etc.)
- A brief reason why the exclusion cannot be (or was not) eliminated

## Instance registry

### Category A — Filename-based exclude lists

| ID | Files | Excluded | Tier | Reason | Verification |
|----|-------|----------|------|--------|-------------|
| A1 | `16-package-manager-enforcement.sh`, `.ps1` | `check.sh`, `check.ps1`, `shell.nix` (+ self-refs) | T2 | Orchestrator/parent config files legitimately contain `pip`/`npm` in comments and error messages; self-refs are dynamic | grep after each run: excluded files still contain pip/npm patterns |
| A2 | `19-config-method-compliance.sh`, `.ps1` | `.gitkeep`, `.gitignore`, `*.schema.json`, `agents/*` | T3 | Infrastructure files are not configs; `agents/*` consumed as directory. Note: `qtpass.nix` removed 2026-07-29 by self-pruning check — file no longer existed | Manual quarterly review |
| A3 | `12-locked-dsc-validation.ps1` | `packages.dsc.yml` | T2 | Packages DSC is generated from lockfile, not manually authored | Verify file still exists |
| A4 | `11-lockfile-validation.ps1` | `lfOverlapExceptions`: `astral-sh.ty` | T2 | Legitimate cross-section overlap in lockfile | Warn if no longer overlaps |
| A5 | `gc.sh`, `gc.ps1` | `index.lock` | T3 | Git invariant — `index.lock` must never be cleaned | Manual quarterly review |
| A6 | `test-lib.sh` | `lib.nix` in test discovery | T2 | Test helper library excluded from namespace of test files | Verify file still exists |
| A7 | `framework-lib.sh`, `framework-lib.ps1` | `*.schema.json` | T3 | Glob pattern for schema files is narrow and stable | Manual quarterly review |

### Category B — Directory-based exclude lists

| ID | Files | Excluded dirs | Tier | Reason | Verification |
|----|-------|---------------|------|--------|-------------|
| B1 | `19-config-method-compliance.sh`, `.ps1` | `vendor/`, `configs/` | T3 | Structural invariants — vendored code and config methods are different concerns | Manual quarterly review |
| B2 | `01-code-formatting.ps1` | `vendor/`, `secrets/` | T3 | Structural invariants | Manual quarterly review |
| B3 | `13-schema-validation.ps1` | `vendor/`, `secrets/` | T3 | Structural invariants | Manual quarterly review |
| B4 | `15-yaml-structural.ps1` | `vendor/`, `secrets/` | T3 | Structural invariants | Manual quarterly review |
| B5 | `17-suppression-audit.ps1` | `vendor/` | T3 | Structural invariant | Manual quarterly review |
| B6 | `21-preflight-install-command-policy.ps1` | `vendor/` | T3 | Structural invariant | Manual quarterly review |
| B7 | `framework-lib.sh`, `framework-lib.ps1` | `vendor/` | T3 | Structural invariant | Manual quarterly review |
| B8 | `cleanup-nix-build-artifacts.sh` | `vendor/` | T3 | Structural invariant | Manual quarterly review |

### Category C — Content-pattern exclude lists (grep -v, notmatch)

| ID | Files | Excluded pattern | Tier | Reason | Verification |
|----|-------|------------------|------|--------|-------------|
| C1 | `script-validation-tests.sh` | `HOME\|TMPDIR\|/tmp\|--` in rm -rf check | T3 | Known-safe patterns in test; false-positive reduction | Manual quarterly review |
| C2 | `script-validation-tests.sh` | `^svc: warning:` in service test | T3 | Runtime warning noise from svc script | Manual quarterly review |
| C3 | `apple-sdk-override.sh` | env vars in nix output filter | T3 | Nix-env debug output suppression | Manual quarterly review |

## Review cadence

- **Quarterly**: full audit of all T3 entries. Check each excluded file still exists, each excluded pattern is still justified, and no new hard-coded exclude lists have been introduced.
- **Trigger**: review is due when a check step is added, removed, or renumbered.
- **Verification**: run `scripts/check.sh` (which includes step 21 for preflight policy) to catch regressions.
