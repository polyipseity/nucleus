# Allow and deny list registry

Loaded policy: `.agents/instructions/allow-and-deny-lists.instructions.md`. This file holds the per-instance registry and the exact IDs cited by `# ref:` annotations.

## Instance registry

A new exclusion needs a category id, tier, and `# ref:`.

### Category A: filename-based

| ID | Files | Excluded | Tier | Reason | Verify |
| --- | --- | --- | --- | --- | --- |
| A2 | `12-repo-policy-pattern.sh`, `.ps1` | `.gitkeep`, `.gitignore`, `*.schema.json`, `agents/*` | T3 | Infrastructure, not configs | Quarterly |
| A5 | `gc.sh`, `gc.ps1` | `index.lock` | T3 | Git invariant | Quarterly |
| A6 | `test-lib.sh` | `lib.nix` | T2 | Test helper excluded from test namespace | File exists |
| A7 | `step-runner.sh`, `.ps1` | `*.schema.json` | T3 | Narrow glob | Quarterly |
| A8 | `07-schema-validation.sh`, `.ps1` | **Schema definitions:** `*.schema.json`. **External formats (no published schema):** `*/users/*/cursor/*.json`, `*/users/*/iterm2/DynamicProfiles/*.json`, `*/users/*/obsidian/*.json`, `*/users/*/qtpass/*.json`, `*/users/*/rimsort/*.json`, `*/configs/camilladsp/*`, `*/configs/camillagui-backend/*`, `*/users/*/discord-music-rpc/*`, `*/users/*/agents/hooks/*.json`, `*/users/*/agents/skills/*/_meta.json`, `*/configs/litellm/*`, `*/users/*/hermes/plugins/*/plugin.yaml`, `*/users/*/claude/plugins/*/.claude-plugin/plugin.json`, `*/users/*/claude/plugins/*/hooks/hooks.json`, `*/users/*/claude/.claude-plugin/marketplace.json`, `*/users/*/vscode/mcp.json`, `*/users/*/vscode/chatLanguageModels*.json`, `*/users/*/pi/litellm-models.json`, `*/users/*/opencode/litellm-provider.json`, `*/users/*/claude/litellm-env.json`, `*/users/*/vscode/litellm-entry.json`, `*/users/*/copilot/litellm-providers.json`, `*/users/*/hermes/litellm-config.yaml`, `*/.sops.yaml`. **Tool config:** `.yamllint.yml` (yamllint's own schema rejects `$schema`). **Infrastructure:** `*/vendor/*`, `*/secrets/*`, `*/.github/*` | T3 | Nucleus-owned data: `$schema` required (we write our own). External formats: use published `$schema` when available; never roll our own. Exempt because injected $schema breaks these merged or external formats. | Quarterly |
| A9 | `11-repo-policy-grep.sh` | self-file (basename) | T3 | Self-ref contains literal patterns detected | Quarterly |
| A10 | `11-repo-policy-grep.sh` | `android-fake-wifi-guest-setup.sh`, `android-fake-wifi-guest-revert.sh` | T3 | The guest has no Nix store, so its `ip`/`modprobe`/`rmmod` cannot resolve against one. The whole file is excluded, not the token. | Quarterly |
| A11 | `scripts/gc.sh` | `command -v` tool lookups | T3 | `scripts/` is outside the scanned `_activation_dirs`, so a lookup here is a relocation, not a stored exclusion. `duperemove-store.sh` takes the binary as `$_duperemove_bin="$1"`, which is the `_X_bin="$1"` contract. A NixOS-only package cannot be added to the `gcWeekly` wrapper's `runtimeInputs` without splitting it. | Quarterly |
| A12 | `11-repo-policy-grep.sh`, `11-repo-policy-grep.ps1` | the repo-policy `.ps1` step leaves in both twins' PowerShell scans; this step's own `.sh` leaf in the shell and Nix scans | T3 | The suppression audit searches for literal suppression-pattern text the step files carry in their own scan definitions. The PowerShell twin keeps two lists: the three `.ps1` step leaves for its PowerShell scans, matching the POSIX twin's ps1 exclusion, and only this step's own `.sh` leaf for its shell and Nix scans, because the sibling leaves' `|| true` occurrences are all `suppression_doc`-annotated, which the audit accepts, and the POSIX twin already scans them | Quarterly |
| A14 | `12-repo-policy-pattern.sh`, `.ps1` | `.envrc` | T3 | The scan walks the whole working tree for this filename because `.envrc` is gitignored and a tracked-file list cannot see it. A repo-local `.envrc` would inject a devShell env into shells at `cd`, the stale GC'd-env failure mode the direnv ban exists to prevent | Quarterly |
| A15 | `12-repo-policy-pattern.sh`, `.ps1` | `store-lock.sh` | T3 | The scan's `return 2` rule cannot tell a skip from a bad-argument exit. `store-lock.sh` returns 2 only after `error "store lock deadline must be whole seconds"`, a usage error that callers and `tests/scripts/store-lock-run-tests.sh` assert, so the file is excluded rather than the token. Registration is required: an unregistered exclusion is invisible to the check and only a review catches it. | Quarterly |

### Category B: directory-based

| ID | Files | Excluded | Tier | Reason | Verify |
| --- | --- | --- | --- | --- | --- |
| B1 | `12-repo-policy-pattern.sh`, `.ps1` | `vendor/`, `configs/` | T3 | Structural invariants | Quarterly |
| B2 | `01-code-formatting.ps1` | `vendor/` | T3 | Speed; secrets by gitignore | Quarterly |
| B3 | `07-schema-validation.ps1` | `vendor/` | T3 | Speed; secrets by gitignore + Select-GitIgnored | Quarterly |
| B6 | `12-repo-policy-pattern.sh`, `.ps1`, `13-repo-policy-data.sh`, `.ps1` | `vendor/` | T3 | Supplemented by Select-GitIgnored | Quarterly |
| B7 | `step-runner.sh`, `.ps1` | `vendor/` | T3 | Supplemented by filter_gitignored/Select-GitIgnored | Quarterly |
| B8 | `cleanup-nix-build-artifacts.sh` | `vendor/` | T3 | Structural | Quarterly |

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
| D7 | `tests/modules/package-lists-tests.nix` | `wingetPinExceptions` | T3 | Ids the microsoft/winget-pkgs repository does not carry: msstore ids by design, plus any registry id with no manifest, each warned by the updater every run; verify msstore ids on Windows with `winget show <id> --source msstore` | Quarterly |
| D8 | `tests/modules/package-lists-tests.nix` | `wingetDscExceptions`: `Valve.SteamCMD` | T2 | The WinGet SteamCMD package installs outside the `steamcmd_install_path` RimSort reads, so `Invoke-SteamCMDSetup.ps1` provisions the binary from Valve's CDN instead of a DSC resource (POSIX twin: `src/scripts/configs/provision-steamcmd.sh`) | Error if stale (`stale WinGet DSC exceptions`) |

### Category E: upstream workarounds

| ID | Files | Entry | Tier | Reason | Verify |
| --- | --- | --- | --- | --- | --- |
| E1 | `src/users/default/agents/skills/nucleus-platform-reference/references/upstream-workarounds.md` | All entries (W01-W24) | T3 | Workarounds for upstream limitations; temporary entries re-checked quarterly, permanent entries listed only | Error if a referenced path is missing (`run_upstream_workaround_staleness`, step 13) |
