---
description: "Reference: per-file exclusion registry (Categories A-D), dummy key management rules. Read on demand when adding, reviewing, or auditing hard-coded denylists and allowlists."
name: "Allow/Deny Instance Registry Reference"
---

# Allow/deny instance registry reference

## Category A — Filename-based

| ID | Files | Excluded | Tier | Reason | Verify |
| --- | --- | --- | --- | --- | --- |
| A1 | `11-package-manager-enforcement.sh`, `.ps1` | `check.sh`, `check.ps1`, `shell.nix` (+ self-refs) | T2 | Contains `pip`/`npm` in comments/errors; self-refs dynamic | grep pip/npm present |
| A2 | `14-repository-policy.sh`, `.ps1` | `.gitkeep`, `.gitignore`, `*.schema.json`, `agents/*` | T3 | Infrastructure, not configs | Quarterly |
| A3 | `06-locked-dsc-validation.ps1` | `packages.dsc.yml` | T2 | Generated from lockfile | File exists |
| A5 | `gc.sh`, `gc.ps1` | `index.lock` | T3 | Git invariant | Quarterly |
| A6 | `test-lib.sh` | `lib.nix` | T2 | Test helper excluded from test namespace | File exists |
| A7 | `step-runner.sh`, `.ps1` | `*.schema.json` | T3 | Narrow glob | Quarterly |
| A8 | `07-schema-validation.sh`, `.ps1` | `*/users/*/vscode/*.json`, `*/users/*/cursor/*.json`, `*/users/*/iterm2/DynamicProfiles/*.json`, `*/users/*/obsidian/*.json`, `*/users/*/qtpass/*.json`, `*/users/*/rimsort/*.json`, `*/configs/camilladsp/*`, `*/configs/camillagui-backend/*`, `*/users/*/discord-music-rpc/*`, `*/users/*/agents/hooks/*.json`, `*/users/*/agents/skills/*/_meta.json`, `*/ai/litellm-config.yml`, `*/.sops.yaml` | T3 | No published schema; vscode:// not fetchable | Quarterly |
| A9 | `12-suppression-audit.ps1` | self-file (basename) | T3 | Self-ref contains literal patterns detected | Quarterly |

## Category B — Directory-based

| ID | Files | Excluded | Tier | Reason | Verify |
| --- | --- | --- | --- | --- | --- |
| B1 | `14-repository-policy.sh`, `.ps1` | `vendor/`, `configs/` | T3 | Structural invariants | Quarterly |
| B2 | `01-code-formatting.ps1` | `vendor/` | T3 | Speed; secrets by gitignore | Quarterly |
| B3 | `07-schema-validation.ps1` | `vendor/` | T3 | Speed; secrets by gitignore + Select-GitIgnored | Quarterly |
| B4 | `09-yaml-structural.ps1` | `vendor/` | T3 | Speed; secrets by gitignore + Select-GitIgnored | Quarterly |
| B5 | `12-suppression-audit.ps1` | `vendor/` | T3 | Supplemented by Select-GitIgnored | Quarterly |
| B6 | `14-repository-policy.ps1` | `vendor/` | T3 | Supplemented by Select-GitIgnored | Quarterly |
| B7 | `step-runner.sh`, `.ps1` | `vendor/` | T3 | Supplemented by filter_gitignored/Select-GitIgnored | Quarterly |
| B8 | `cleanup-nix-build-artifacts.sh` | `vendor/` | T3 | Structural | Quarterly |

## Category C — Content-pattern (grep -v)

| ID | Files | Pattern | Tier | Reason | Verify |
| --- | --- | --- | --- | --- | --- |
| C1 | `script-validation-tests.sh` | `HOME\|TMPDIR\|/tmp\|--` rm -rf | T3 | Known-safe test patterns | Quarterly |
| C2 | `script-validation-tests.sh` | `^svc: warning:` | T3 | Runtime noise | Quarterly |
| C3 | `apple-sdk-override.sh` | env vars in nix output | T3 | Debug suppression | Quarterly |
| C4 | `scripts/check.sh packer` | `Warning: A checksum of 'none'...` block | T3 | No stable Win11 checksums; `iso_checksum = "none"` intentional in `src/vms/Windows/packer.pkr.hcl` (39, 228) | Quarterly |
| C5 | `14-repository-policy.sh`, `.ps1` | self-file | T3 | Self-ref contains literal patterns | Quarterly |

## Category D — Allowlists

| ID | Files | Entry | Tier | Reason | Verify |
| --- | --- | --- | --- | --- | --- |
| D1 | `05-lockfile-validation.ps1` | `lfOverlapExceptions`: `astral-sh.ty` | T2 | Legitimate overlap | Error if stale |
| D2 | `lifecycle-allowlist.json` | All entries | T2 | Supply-chain hardening | Error if stale (`check.sh`) |
| D3 | `supply-chain-hardening.instructions.md` | Allowlist (cross-ref) | — | External | See that file |

## Dummy key management

Registry: `src/modules/dummy-keys.json` (validated against `src/modules/dummy-keys.schema.json`).

- `sk-` + 4+ alphanumerics placeholder → must resolve to `dummyKeys.<name>.value`.
- New entries: `value` (exact literal), `consumers` (paths), `note` (why).
- Consumers use registry `value` verbatim.
- Step 14 (`run_dummy_key_uniformity`) enforces.
