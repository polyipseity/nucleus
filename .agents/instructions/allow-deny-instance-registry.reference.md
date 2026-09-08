---
description: "Reference: per-file exclusion registry (Categories A-D), dummy key management rules. Read on demand when adding, reviewing, or auditing hard-coded denylists and allowlists."
name: "Allow/Deny Instance Registry Reference"
---

# Allow/deny instance registry reference

## Category A — Filename-based exclude lists

| ID | Files | Excluded | Tier | Reason | Verification |
| --- | --- | --- | --- | --- | --- |
| A1 | `11-package-manager-enforcement.sh`, `.ps1` | `check.sh`, `check.ps1`, `shell.nix` (+ self-refs) | T2 | Orchestrator/parent config files contain `pip`/`npm` in comments and error messages; self-refs are dynamic | grep: excluded files still contain pip/npm patterns |
| A2 | `14-repository-policy.sh`, `.ps1` | `.gitkeep`, `.gitignore`, `*.schema.json`, `agents/*` | T3 | Infrastructure files, not configs; `agents/*` consumed as directory | Quarterly |
| A3 | `06-locked-dsc-validation.ps1` | `packages.dsc.yml` | T2 | Generated from lockfile, not manually authored | Verify file exists |
| A5 | `gc.sh`, `gc.ps1` | `index.lock` | T3 | Git invariant — must never be cleaned | Quarterly |
| A6 | `test-lib.sh` | `lib.nix` in test discovery | T2 | Test helper excluded from test file namespace | Verify file exists |
| A7 | `step-runner.sh`, `step-runner.ps1` | `*.schema.json` | T3 | Narrow, stable glob | Quarterly |
| A8 | `07-schema-validation.sh`, `.ps1` | `*/users/*/vscode/*.json`, `*/users/*/cursor/*.json`, `*/users/*/iterm2/DynamicProfiles/*.json`, `*/users/*/obsidian/*.json`, `*/users/*/qtpass/*.json`, `*/users/*/rimsort/*.json`, `*/configs/camilladsp/*`, `*/configs/camillagui-backend/*`, `*/users/*/discord-music-rpc/*`, `*/users/*/agents/hooks/*.json`, `*/users/*/agents/skills/*/_meta.json`, `*/ai/litellm-config.yml`, `*/.sops.yaml` | T3 | No published JSON schema; vscode:// URIs not fetchable by check-jsonschema (Spec G) | Quarterly |
| A9 | `12-suppression-audit.ps1` | self-file (basename) | T3 | Self-reference — scan definitions contain literal suppression patterns being detected | Quarterly |

## Category B — Directory-based exclude lists

| ID | Files | Excluded dirs | Tier | Reason | Verification |
| --- | --- | --- | --- | --- | --- |
| B1 | `14-repository-policy.sh`, `.ps1` | `vendor/`, `configs/` | T3 | Structural invariants | Quarterly |
| B2 | `01-code-formatting.ps1` | `vendor/` | T3 | Speed; secrets/ covered by gitignore (treefmt respects .gitignore) | Quarterly |
| B3 | `07-schema-validation.ps1` | `vendor/` | T3 | Speed; secrets/ covered by gitignore + Select-GitIgnored | Quarterly |
| B4 | `09-yaml-structural.ps1` | `vendor/` | T3 | Speed; secrets/ covered by gitignore + Select-GitIgnored | Quarterly |
| B5 | `12-suppression-audit.ps1` | `vendor/` | T3 | Structural invariant; supplemented by Select-GitIgnored | Quarterly |
| B6 | `14-repository-policy.ps1` | `vendor/` | T3 | Structural invariant; supplemented by Select-GitIgnored | Quarterly |
| B7 | `step-runner.sh`, `step-runner.ps1` | `vendor/` | T3 | Structural invariant; supplemented by filter_gitignored/Select-GitIgnored | Quarterly |
| B8 | `cleanup-nix-build-artifacts.sh` | `vendor/` | T3 | Structural invariant | Quarterly |

## Category C — Content-pattern exclude lists (grep -v, notmatch)

| ID | Files | Excluded pattern | Tier | Reason | Verification |
| --- | --- | --- | --- | --- | --- |
| C1 | `script-validation-tests.sh` | `HOME\|TMPDIR\|/tmp\|--` in rm -rf check | T3 | Known-safe test patterns | Quarterly |
| C2 | `script-validation-tests.sh` | `^svc: warning:` | T3 | Runtime warning noise | Quarterly |
| C3 | `apple-sdk-override.sh` | env vars in nix output filter | T3 | Debug output suppression | Quarterly |
| C4 | `scripts/check.sh packer` | `Warning: A checksum of 'none' was specified … (source code not available)` | T3 | No stable Windows 11 ISO checksums from Microsoft; `iso_checksum = "none"` intentional in `src/vms/Windows/packer.pkr.hcl` (lines 39, 228); exit code enforced | Quarterly |
| C5 | `14-repository-policy.sh`, `.ps1` | self-file (`basename "${BASH_SOURCE[0]}"` / `Split-Path -Leaf $PSCommandPath`) | T3 | Self-refs contain literal heredoc/here-string patterns being detected | Quarterly |

## Category D — Allowlists

| ID | Files | Allowed entry | Tier | Reason | Verification |
| --- | --- | --- | --- | --- | --- |
| D1 | `05-lockfile-validation.ps1` | `lfOverlapExceptions`: `astral-sh.ty` | T2 | Legitimate cross-section overlap | Error if stale |
| D2 | `lifecycle-allowlist.json` | All entries | T2 | Supply-chain hardening: lifecycle hooks permitted for listed packages | Error if stale (via `check.sh`) |
| D3 | `supply-chain-hardening.instructions.md` | Allowlist mechanism (cross-reference) | — | External allowlist | See that file |

## Dummy key management

Registry: `src/modules/dummy-keys.json`, validated against `src/modules/dummy-keys.schema.json`.

- Any `sk-` + 4+ alphanumerics placeholder in tracked config must resolve to `dummyKeys.<name>.value`.
- New entries: `value` (exact literal), `consumers` (repo-relative paths), `note` (why it exists).
- Consumers must use the registry `value` verbatim.
- Step 14 (`run_dummy_key_uniformity`) enforces registration.
