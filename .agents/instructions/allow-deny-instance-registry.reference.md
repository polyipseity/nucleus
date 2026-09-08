---
description: "Reference: per-file exclusion registry (Categories A-D), dummy key management rules. Read on demand when adding, reviewing, or auditing hard-coded denylists and allowlists."
name: "Allow/Deny Instance Registry Reference"
---

# Allow/deny instance registry reference

## Category A — Filename-based exclude lists

| ID | Files | Excluded | Tier | Reason | Verification |
| --- | ------------------------------------------- | ----------------------------------------------------- | ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------ |
| A1 | `11-package-manager-enforcement.sh`, `.ps1` | `check.sh`, `check.ps1`, `shell.nix` (+ self-refs) | T2 | Orchestrator/parent config files legitimately contain `pip`/`npm` in comments and error messages; self-refs are dynamic | grep after each run: excluded files still contain pip/npm patterns |
| A2 | `14-repository-policy.sh`, `.ps1` | `.gitkeep`, `.gitignore`, `*.schema.json`, `agents/*` | T3 | Infrastructure files are not configs; `agents/*` consumed as directory | Manual quarterly review |
| A3 | `06-locked-dsc-validation.ps1` | `packages.dsc.yml` | T2 | Packages DSC is generated from lockfile, not manually authored | Verify file still exists |
| A5 | `gc.sh`, `gc.ps1` | `index.lock` | T3 | Git invariant — `index.lock` must never be cleaned | Manual quarterly review |
| A6 | `test-lib.sh` | `lib.nix` in test discovery | T2 | Test helper library excluded from namespace of test files | Verify file still exists |
| A7 | `step-runner.sh`, `step-runner.ps1` | `*.schema.json` | T3 | Glob pattern for schema files is narrow and stable | Manual quarterly review |
| A8 | `07-schema-validation.sh`, `.ps1` | App-owned config formats in $schema EXCEPTION_LIST: `*/users/*/vscode/*.json`, `*/users/*/cursor/*.json`, `*/users/*/iterm2/DynamicProfiles/*.json`, `*/users/*/obsidian/*.json`, `*/users/*/qtpass/*.json`, `*/users/*/rimsort/*.json`, `*/configs/camilladsp/*`, `*/configs/camillagui-backend/*`, `*/users/*/discord-music-rpc/*`, `*/users/*/agents/hooks/*.json`, `*/users/*/agents/skills/*/_meta.json`, `*/ai/litellm-config.yml`, `*/.sops.yaml` | T3 | No published JSON schema exists; vscode:// URIs not fetchable by check-jsonschema (Spec G) | Manual quarterly review |
| A9 | `12-suppression-audit.ps1` | self-file (basename) | T3 | Self-reference — scan definitions contain the literal suppression patterns being detected; `\| Out-Null` self-flags cannot be annotation-suppressed (NoSuppressionCheck) | Manual quarterly review |

## Category B — Directory-based exclude lists

| ID | Files | Excluded dirs | Tier | Reason | Verification |
| --- | ----------------------------------------- | --------------------- | ---- | ---------------------------------------------------------------------------------------------------------- | ----------------------- |
| B1 | `14-repository-policy.sh`, `.ps1` | `vendor/`, `configs/` | T3 | Structural invariants — vendored code and config methods are different concerns | Manual quarterly review |
| B2 | `01-code-formatting.ps1` | `vendor/` | T3 | Structural invariant (vendor/ speed); secrets/ covered by gitignore (treefmt natively respects .gitignore) | Manual quarterly review |
| B3 | `07-schema-validation.ps1` | `vendor/` | T3 | Structural invariant (vendor/ speed); secrets/ dropped — covered by gitignore + Select-GitIgnored | Manual quarterly review |
| B4 | `09-yaml-structural.ps1` | `vendor/` | T3 | Structural invariant (vendor/ speed); secrets/ dropped — covered by gitignore + Select-GitIgnored | Manual quarterly review |
| B5 | `12-suppression-audit.ps1` | `vendor/` | T3 | Structural invariant; supplemented by Select-GitIgnored | Manual quarterly review |
| B6 | `14-repository-policy.ps1` | `vendor/` | T3 | Structural invariant; supplemented by Select-GitIgnored | Manual quarterly review |
| B7 | `step-runner.sh`, `step-runner.ps1` | `vendor/` | T3 | Structural invariant; supplemented by filter_gitignored/Select-GitIgnored | Manual quarterly review |
| B8 | `cleanup-nix-build-artifacts.sh` | `vendor/` | T3 | Structural invariant | Manual quarterly review |

## Category C — Content-pattern exclude lists (grep -v, notmatch)

| ID | Files | Excluded pattern | Tier | Reason | Verification |
| --- | ---------------------------- | ---------------------------------------- | ---- | ----------------------------------------------------- | ----------------------- |
| C1 | `script-validation-tests.sh` | `HOME\|TMPDIR\|/tmp\|--` in rm -rf check | T3 | Known-safe patterns in test; false-positive reduction | Manual quarterly review |
| C2 | `script-validation-tests.sh` | `^svc: warning:` in service test | T3 | Runtime warning noise from svc script | Manual quarterly review |
| C3 | `apple-sdk-override.sh` | env vars in nix output filter | T3 | Nix-env debug output suppression | Manual quarterly review |
| C4 | `scripts/check.sh packer` | `Warning: A checksum of 'none' was specified … (source code not available)` block | T3 | Microsoft publishes no stable Windows 11 ISO checksums; `iso_checksum = "none"` intentional in `src/vms/Windows/packer.pkr.hcl` (lines 39, 228); exit code still enforced | Manual quarterly review |
| C5 | `14-repository-policy.sh`, `.ps1` | self-file (`basename "${BASH_SOURCE[0]}"` / `Split-Path -Leaf $PSCommandPath`) | T3 | Self-refs are dynamic — the source contains the literal heredoc/here-string patterns being detected | Manual quarterly review |

## Category D — Allowlists

| ID | Files | Allowed entry | Tier | Reason | Verification |
| --- | ---------------------------------------- | ------------------------------------- | ---- | --------------------------------------------------------------------- | ------------------------------- |
| D1 | `05-lockfile-validation.ps1` | `lfOverlapExceptions`: `astral-sh.ty` | T2 | Legitimate cross-section overlap in lockfile | Error if stale |
| D2 | `lifecycle-allowlist.json` | All entries | T2 | Supply-chain hardening: lifecycle hooks permitted for listed packages | Error if stale (via `check.sh`) |
| D3 | `supply-chain-hardening.instructions.md` | Allowlist mechanism (cross-reference) | — | External allowlist maintained in supply-chain-hardening docs | See that file |

## Dummy key management

Dummy-key registry: `src/modules/dummy-keys.json`, validated against `src/modules/dummy-keys.schema.json`.

- Any dummy/placeholder API-key literal of the form `sk-` followed by 4+ alphanumerics hardcoded in a tracked config must resolve to a registered `dummyKeys.<name>.value`.
- New entries need three fields: `value` (the exact literal consumers use), `consumers` (repo-relative paths of configs using it), and `note` (why it exists).
- Consumers must use the registry `value` verbatim.
- Check step 14 (`run_dummy_key_uniformity` in `src/scripts/checks/check-steps/14-repository-policy.sh` / `.ps1`) enforces registration; keep the check in sync with registry shape changes.
