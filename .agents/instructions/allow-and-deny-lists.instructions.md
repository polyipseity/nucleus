---
description: "Use when authoring or reviewing hard-coded denylists and allowlists. Covers tiers (T1/T2/T3), per-file exclusion registry (Categories A-D), dummy key management rules, and review schedule."
name: "Allow and Deny List Policy"
applyTo: "scripts/**, src/**, tests/**"
---

# Allow and deny list policy

Every hard-coded filter list carries a category id, a justification, and a tier.

## Tiers

1. **T1 (Eliminate).** Remove or replace with dynamic discovery.
2. **T2 (Self-prune, must error).** Post-check: confirm each exclusion still holds. Stale → error.
3. **T3 (Track).** `# ref: allow-and-deny-lists.instructions.md` at site. Quarterly review.

## Gitignore-based denylist

`src/scripts/lib/deny-list.sh` (`filter_gitignored`, `find_git_tracked`), `deny-list.ps1` (`Select-GitIgnored`, `Get-GitTrackedFile`).

1. File lists pipe through the filter. `step-runner.sh` does it inside `cache_file_lists()`; POSIX check steps 11, 12, 13 and PowerShell steps 07, 11, 12, 13 call it themselves.
2. Hard-coded exclusions only for non-gitignore reasons. Drop `.gitignore` duplicates.
3. Structural dir exclusions (`vendor/`) as find `-prune` plus the filter, Category B.
4. `git` is required; a missing one fails `require_command` in the step-runner preflight.

## Instance registry

A new exclusion needs a category id, tier, and `# ref:`.

### Category A: filename-based

| ID | Files | Excluded | Tier | Reason | Verify |
| --- | --- | --- | --- | --- | --- |
| A2 | `12-repo-policy-pattern.sh`, `.ps1` | `.gitkeep`, `.gitignore`, `*.schema.json`, `agents/*` | T3 | Infrastructure, not configs | Quarterly |
| A5 | `gc.sh`, `gc.ps1` | `index.lock` | T3 | Git invariant | Quarterly |
| A6 | `test-lib.sh` | `lib.nix` | T2 | Test helper excluded from test namespace | File exists |
| A7 | `step-runner.sh`, `.ps1` | `*.schema.json` | T3 | Narrow glob | Quarterly |
| A8 | `07-schema-validation.sh`, `.ps1` | **Schema definitions:** `*.schema.json`. **External formats (no published schema):** `*/users/*/cursor/*.json`, `*/users/*/iterm2/DynamicProfiles/*.json`, `*/users/*/obsidian/*.json`, `*/users/*/qtpass/*.json`, `*/users/*/rimsort/*.json`, `*/configs/camilladsp/*`, `*/configs/camillagui-backend/*`, `*/users/*/discord-music-rpc/*`, `*/users/*/agents/hooks/*.json`, `*/users/*/agents/skills/*/_meta.json`, `*/configs/litellm/*`, `*/users/*/hermes/plugins/*/plugin.yaml`, `*/users/*/vscode/mcp.json`, `*/users/*/vscode/chatLanguageModels*.json`, `*/.sops.yaml`. **Tool config:** `.yamllint.yml` (yamllint's own schema rejects `$schema`). **Infrastructure:** `*/vendor/*`, `*/secrets/*`, `*/.github/*` | T3 | Nucleus-owned data: `$schema` required (we write our own). External formats: use published `$schema` when available; never roll our own. Exempt when no published schema exists. | Quarterly |
| A9 | `11-repo-policy-grep.sh` | self-file (basename) | T3 | Self-ref contains literal patterns detected | Quarterly |
| A10 | `11-repo-policy-grep.sh` | `android-fake-wifi-guest-setup.sh`, `android-fake-wifi-guest-revert.sh` | T3 | The guest has no Nix store, so its `ip`/`modprobe`/`rmmod` cannot resolve against one. The whole file is excluded, not the token. | Quarterly |
| A11 | `scripts/gc.sh` | `command -v` tool lookups | T3 | `scripts/` is outside the scanned `_activation_dirs`, so a lookup here is a relocation, not a stored exclusion. `duperemove-store.sh` takes the binary as `$_duperemove_bin="$1"`, which is the `_X_bin="$1"` contract. A NixOS-only package cannot be added to the `gcWeekly` wrapper's `runtimeInputs` without splitting it. | Quarterly |
| A12 | `11-repo-policy-grep.sh` | patterns `repo-policy-.*\.(sh\|ps1)`, `repository-policy.*\.(sh\|ps1)`, `1[123]-repo-policy-.*\.sh` (stored list, not filenames) | T3 | The package-manager scan bans bare `pip`/`npm` install and the step files carry that literal in their own patterns and error strings. The list is a superset of what exists: the first matches nothing, the second matches `repository-policy-awk-tests.sh`, the third the six step files plus their tests. Excluded by basename and glob in the whole-repo branch; `$pmeExcludeNames` in the twin | Quarterly |
| A13 | `11-repo-policy-grep.sh` | `configure-gpg-agent.sh` | T3 | Part of the store-path-arg `_exclude_pattern` in `run_store_path_arg_usage`: its `_*_bin` variables are config parameters, not commands. The self-file basenames in the same pattern are A9; the android guest scripts are A10, excluded by a separate list in `run_activation_tool_resolution` | Quarterly |

### Category B: directory-based

| ID | Files | Excluded | Tier | Reason | Verify |
| --- | --- | --- | --- | --- | --- |
| B1 | `12-repo-policy-pattern.sh`, `.ps1` | `vendor/`, `configs/` | T3 | Structural invariants | Quarterly |
| B2 | `01-code-formatting.ps1` | `vendor/` | T3 | Speed; secrets by gitignore | Quarterly |
| B3 | `07-schema-validation.ps1` | `vendor/` | T3 | Speed; secrets by gitignore + Select-GitIgnored | Quarterly |
| B6 | `12-repo-policy-pattern.sh`, `.ps1`, `13-repo-policy-data.sh`, `.ps1` | `vendor/` | T3 | Supplemented by Select-GitIgnored | Quarterly |
| B7 | `step-runner.sh`, `.ps1` | `vendor/` | T3 | Supplemented by filter_gitignored/Select-GitIgnored | Quarterly |
| B8 | `cleanup-nix-build-artifacts.sh` | `vendor/` | T3 | Structural | Quarterly |
| B9 | `11-repo-policy-grep.sh`, `.ps1` | `tests/` in the srt wrapper scan only | T3 | Scoped mode receives whatever file the caller passes, so the hook would scan test files the whole-repo branch never reads. The suite proving the rule has to carry a violating example, and a fixture string is not a shipped wrapper | Quarterly |

### Category C: content pattern (grep -v)

| ID | Files | Pattern | Tier | Reason | Verify |
| --- | --- | --- | --- | --- | --- |
| C3 | `apple-sdk-override.sh` | env vars in nix output | T3 | Debug suppression | Quarterly |
| C4 | `scripts/check.sh packer` | `Warning: A checksum of 'none'...` block | T3 | No stable Win11 checksums; `iso_checksum = "none"` is intentional in `src/vms/Windows/packer.pkr.hcl` | Quarterly |
| C5 | `12-repo-policy-pattern.sh`, `.ps1`, `13-repo-policy-data.sh`, `.ps1` | self-file | T3 | Self-ref contains literal patterns | Quarterly |

### Category D: allowlists

| ID | Files | Entry | Tier | Reason | Verify |
| --- | --- | --- | --- | --- | --- |
| D1 | `05-lockfile-validation.ps1` | `lfOverlapExceptions`: `astral-sh.ty`, `Windows` | T2 | `astral-sh.ty`: legitimate overlap. `Windows`: host key in `suggestions.vm-setup`, not a package name; overlaps with `suggestions.ollama.Windows` | Error if stale |
| D2 | `lifecycle-allowlist.json` | All entries | T2 | Supply-chain hardening | Error if stale (`check.sh`) |
| D3 | `supply-chain-hardening.instructions.md` | Allowlist (cross-ref) | — | External | See that file |
| D4 | `tests/modules/posix-module-imports-tests.nix` | `hostScopedModules`: `security.nix` | T2 | `security.sudo` is NixOS-only, so the macOS-shared `posix/` aggregator cannot carry `security.nix`; the NixOS host imports it directly | Error if stale (`nix-tests`) |
| D5 | `tests/platforms/Windows/modules/gc-parity.Tests.ps1` | `$DestructiveCommands` | T2 | A command absent from the list is silently skipped by the dry-run guard walk, so renaming a helper in `scripts/gc.ps1` disarms the coverage check instead of failing it | Error if stale (`has no stale entry in the destructive-command list`) |
| D6 | `tests/platforms/Windows/modules/gc-parity.Tests.ps1` | `$PosixOnlyCapabilities` | T2 | The list must name exactly the switches `gc.ps1` documents as POSIX-only | Error if stale (`documents exactly the POSIX-only capabilities as accepted and ignored`) |

## Dummy keys

`src/modules/dummy-keys.json`, validated against `src/modules/dummy-keys.schema.json`. A `sk-` placeholder of 4 or more alphanumerics must resolve to `dummyKeys.<name>.value`, consumers use that value verbatim, and every entry carries `value`, `consumers`, and `note`. Step 13 (`run_dummy_key_uniformity`) enforces it.

## Review

Quarterly audit of the T3 rows: files still exist, patterns still justified, no new hard-coded excludes. Also re-review when a check step is added, removed, or renumbered. Last reviewed 2026-09-30.
