---
description: "Use when embedding or extracting file content (config templates, profile content, start scripts, wrappers) in Nix, shell, or PowerShell scripts. Covers the no-embedding invariant, shared cross-platform content, token conventions, and documented exceptions."
name: "Embedded Content Policy"
applyTo: "src/**/*.nix, src/**/*.ps1, src/**/*.sh, src/hosts/Windows/**/*.yml, src/scripts/**, src/vms/**, scripts/**"
---

# Embedded content policy

## Invariant

File content (config templates, profile content, start scripts, wrappers, Caddyfiles, READMEs) lives in dedicated files, never in script string literals (here-strings, string arrays, heredocs, `Add-Content`/`Set-Content`). Every platform, every script type. Exceptions below need `# check-suppress:embedded-content:` at the call site.

## Platform matrix

| Platform | Content location | Read mechanism | Token |
| --- | --- | --- | --- |
| POSIX, Nix eval | `src/scripts/`, `src/modules/configs/` | `builtins.readFile` | `__TOKEN__` via `builtins.replaceStrings` |
| POSIX, sh runtime | adjacent under `src/scripts/` | SCRIPT_DIR-relative (`# shellcheck source=`) | `__TOKEN__` via `sed` |
| Windows, PS runtime | `src/platforms/Windows/modules/scripts/<name>` or shared `src/scripts/` | `Get-Content -Raw (Join-Path $PSScriptRoot '..\scripts\<name>')` | `__TOKEN__` via `-replace` |
| VM templates | `src/vms/templates/` | `Get-Content -Raw` + `.Replace` (Win), `sed` (POSIX) | `__TOKEN__` |
| App configs | `src/modules/configs/` | `ConfigHelpers.ps1`; Nix `home.file` | — |

Windows runtime reads work because `apply.ps1` runs from the live checkout.

## Shared cross-platform content

Same language + same purpose → single shared file. No per-platform duplicates. Shared files in `src/scripts/` (VM: `src/vms/templates/`). Platform divergence: conditionals or `__TOKEN__` per consumer. Per-platform file only when language/semantics differ; cite at both file and consumer.

Registry: `src/scripts/shell/profile.ps1`, `src/scripts/vms/start-android-vm.ps1`, `src/scripts/vms/android-fake-wifi-guest-setup.sh`, `src/scripts/vms/android-fake-wifi-guest-revert.sh`, `src/vms/templates/*`.

## Token convention

- Placeholders: `__UPPER_SNAKE__` everywhere. `{{TOKEN}}` prohibited.
- Every token must be replaced by every consumer or have a documented default.
- Token registry: header comment per file.
- Comments must not contain `__UPPER_SNAKE__` — check step 14 greps. Reference without delimiters (`start-<VM_NAME>.sh`).

## Exceptions

Each needs `# check-suppress:embedded-content:` naming letter and reason:

1. **Data-driven/generated** — loops, JSON-derived text (vhost blocks in `Sync-CaddyService.ps1`, rclone wrapper in `Sync-CloudDriveCatalog.ps1`, PATH snippets, `$virtiofsArgs` in `Invoke-VMSetup.ps1`, host-kind heredocs in `vm.sh`).
2. **Trivial static** — under 10 lines (`.cmd` wrapper in `Invoke-AgentHostShellSetup.ps1`, README placeholder, ssh/ignore template in `Sync-GitAndSshConfig.ps1`).
3. **C# interop** — `Add-Type` inline up to 25 lines (`Sync-UserPath.ps1`, `CamillaDSP-autoconfig.ps1`); beyond → `modules/scripts/*.cs`. **Quarterly (D5)**: extract blocks >25 lines.
4. **Split-pattern** — static body extracted, dynamic wrapper inline (see `nix-and-script-authoring.instructions.md`).
5. **DSC `Script` resources** — Get/Test/Set inline (API requirement), 1–3 lines; grow → `modules/scripts/`. **Quarterly (D6)**: extract blocks >~10 lines.

Structured data (git config, sshd_config keys, wallpaper registry values, JSON/INI merge data) is NOT file content — passed as parameters/hashtables, exempt.

## Lint

- `.ps1` under `modules/scripts/` and `src/scripts/` → `scripts/check-pwsh.ps1` (PSScriptAnalyzer per `pwsh-lint-policy.instructions.md`).
- `.sh` templates under `src/vms/templates/` → `scripts/check.sh sh`; `__TOKEN__` must not trigger shellcheck.
- `# check-suppress:` carries from embedded strings to extracted files.
