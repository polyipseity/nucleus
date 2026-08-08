---
description: "Use when embedding or extracting file content (config templates, profile content, start scripts, wrappers) in Nix, shell, or PowerShell scripts. Covers the no-embedding invariant, shared cross-platform content, token conventions, and documented exceptions."
name: "Embedded Content Policy"
applyTo: "src/**/*.nix, src/**/*.ps1, src/**/*.sh, src/hosts/Windows/**/*.yml, src/scripts/**, src/vms/**, scripts/**"
---

# Embedded content policy

Canonical cross-platform policy for file content inside scripts. Supersedes the platform-specific extraction guidance in `scripts-and-permissions.instructions.md` (PowerShell here-string extraction) and `nix-authoring.instructions.md` (inline code extraction boundaries); those files keep their mechanical examples and point back here.

## Invariant

File content — config templates, shell/PowerShell profile content, start scripts, service wrappers, Caddyfiles, READMEs — lives in dedicated files on disk, never in script string literals (here-strings, string arrays, heredocs, `Add-Content`/`Set-Content` text). This holds on every platform and for every script type (Nix, POSIX sh, PowerShell). The only exceptions are listed in "Exceptions" below and must be cited with an inline `# check-suppress:embedded-content:` comment at the call site.

## Platform matrix

Where content files live and how consumers read them:

| Platform | Content location | Read mechanism | Token convention |
| --- | --- | --- | --- |
| POSIX, Nix eval time | `src/scripts/`, `src/modules/configs/` | `builtins.readFile` | `__TOKEN__` via `builtins.replaceStrings` |
| POSIX, sh runtime | adjacent under `src/scripts/` | SCRIPT_DIR-relative read (`# shellcheck source=`) | `__TOKEN__` via `sed` |
| Windows, PowerShell runtime | `src/platforms/Windows/modules/scripts/<name>` (Windows-only) or shared `src/scripts/` | `Get-Content -Raw (Join-Path -Path $PSScriptRoot -ChildPath '..\scripts\<name>')` | `__TOKEN__` via `-replace '__TOKEN__', $value` |
| VM templates (shared) | `src/vms/templates/` | `Get-Content -Raw` + `.Replace` (Windows), `sed` (POSIX) | `__TOKEN__` |
| App configs | `src/modules/configs/` | `ConfigHelpers.ps1` methods; Nix `home.file` | — |

Windows runtime reads work because `apply.ps1` runs from the live repo checkout (`$PSScriptRoot`-relative paths resolve). No deployment step is needed for content files.

## Shared cross-platform content

Content with analogous semantics across platforms MUST be a single shared file, not one file per platform. "Analogous" means same language and same purpose (e.g. the PowerShell profile body used by both `pwsh.nix` on POSIX and `Sync-ShellProfile.ps1` on Windows; the Android VM QEMU start script used by both `vm.sh` and the Windows module).

- Shared files live in `src/scripts/` (or `src/vms/templates/` for VM templates).
- Platform divergence inside a shared file uses runtime conditionals (`$IsWindows`, `$IsMacOS`, `$IsLinux` in PowerShell content) or `__TOKEN__` values supplied per consumer.
- A per-platform file is allowed only when the language differs or the semantics genuinely differ; the difference must be cited in a comment at both the file and its consumer.
- Registry of shared files (keep current as new shared files land): `src/scripts/shell/profile.ps1` (profile body), `src/scripts/vms/start-android-vm.ps1` (Android QEMU start), `src/scripts/vms/android-fake-wifi-guest-setup.sh` and `src/scripts/vms/android-fake-wifi-guest-revert.sh` (Android guest Magisk scripts), `src/vms/templates/*` (VM templates).

## Token convention

- Placeholders are `__UPPER_SNAKE__` on ALL platforms. The `{{TOKEN}}` form is prohibited everywhere (including POSIX files).
- Token completeness: every token in a shared content file MUST be replaced by every consumer, or have a documented default in the consumer.
- Registry of tokens per file lives with the file (header comment listing its tokens).
- Comments must never contain `__UPPER_SNAKE__`-delimited names — check step 14 (`repository-policy` activation-token sub-check) greps `^\s*#.*__[A-Z][A-Z_]*__` and in scoped mode scans staged `*.sh`/`*.zsh` including `tests/` and `src/vms/templates/*.sh`. Refer to placeholders without delimiters (`start-<VM_NAME>.sh` style).

## Exceptions

Each exception requires an inline `# check-suppress:embedded-content:` comment naming the exception letter and giving the reason:

1. **Data-driven/generated content** — per-entry loops and JSON-derived text (vhost blocks in `Sync-CaddyService.ps1`, rclone wrapper in `Sync-CloudDriveCatalog.ps1`, PATH snippets, `$virtiofsArgs` in `Invoke-VMSetup.ps1`, host-kind heredocs in `vm.sh`). The loop structure IS the script expression.
2. **Trivial static content** — under 10 lines (`.cmd` wrapper in `Invoke-AgentHostShellSetup.ps1`, README fallback in `Invoke-VMSetup.ps1`, ssh block and ignore template in `Sync-GitAndSshConfig.ps1`).
3. **C# interop** — `Add-Type` P/Invoke classes stay inline up to 25 lines (`Sync-UserPath.ps1`, `CamillaDSP-autoconfig.ps1`); beyond that extract to `modules/scripts/*.cs` and read via `Get-Content -Raw` + `Add-Type -TypeDefinition`. **Quarterly check (D5)**: re-measure the `Add-Type` blocks in `Sync-UserPath.ps1` and `CamillaDSP-autoconfig.ps1`; any block over 25 lines must be extracted to `modules/scripts/*.cs` in the same review.
4. **Split-pattern** — static body extracted to a file, dynamic Nix/PowerShell wrapper stays inline (see `nix-authoring.instructions.md`, "Inline code extraction boundaries").
5. **DSC `Script` resources** — Get/Test/Set must stay inline (API requirement) but must remain trivial (1–3 lines); move logic to a `modules/scripts/` file invoked from the resource if it grows. **Quarterly check (D6)**: scan `src/hosts/Windows/**/*.dsc.yml` `Script` resources; any block exceeding ~10 lines or containing substantial logic is moved to a `modules/scripts/` file invoked from the resource in the same review.

Data-driven managed settings (git config, sshd_config keys, wallpaper registry values, JSON/INI merge data) are NOT file content — they are structured data passed as parameters or hashtables (`ConfigHelpers.ps1`), and are exempt from this policy entirely.

## Lint integration

- Extracted `.ps1` content files under `modules/scripts/` and `src/scripts/` are linted by `scripts/check-pwsh.ps1` (`git ls-files '*.ps1'`); they MUST pass PSScriptAnalyzer per `pwsh-lint-policy.instructions.md`.
- Extracted `.sh` templates under `src/vms/templates/` are checked by `scripts/check-sh.sh`; `__TOKEN__` placeholders must not trigger shellcheck (quote-check them).
- `# check-suppress:` inline comments carry over verbatim from embedded strings to extracted files.

## Related instruction files

- `scripts-and-permissions.instructions.md` — PowerShell here-string extraction mechanics and script placement.
- `nix-authoring.instructions.md` — inline code extraction boundaries (Nix side).
- `app-config-policy.instructions.md` — config deployment methods (symlink/read-only/merge).
- `pwsh-lint-policy.instructions.md` — PSScriptAnalyzer suppression rules.
