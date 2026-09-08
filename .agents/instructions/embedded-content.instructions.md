---
description: "Use when embedding or extracting file content (config templates, profile content, start scripts, wrappers) in Nix, shell, or PowerShell scripts. Covers the no-embedding invariant, shared cross-platform content, token conventions, and documented exceptions."
name: "Embedded Content Policy"
applyTo: "src/**/*.nix, src/**/*.ps1, src/**/*.sh, src/hosts/Windows/**/*.yml, src/scripts/**, src/vms/**, scripts/**"
---

# Embedded content policy

## Invariant

File content (config templates, profile content, start scripts, wrappers, Caddyfiles, READMEs) lives in dedicated files, never in script string literals. Every platform, every script type. Exceptions need `# check-suppress:embedded-content:` at the call site.

## Platform matrix

| Platform | Content location | Read mechanism | Token |
| --- | --- | --- | --- |
| POSIX, Nix eval | `src/scripts/`, `src/modules/configs/` | `builtins.readFile` | `__TOKEN__` via `builtins.replaceStrings` |
| POSIX, sh runtime | adjacent under `src/scripts/` | SCRIPT_DIR-relative (`# shellcheck source=`) | `__TOKEN__` via `sed` |
| Windows, PS runtime | `src/platforms/Windows/modules/scripts/<name>` or shared `src/scripts/` | `Get-Content -Raw (Join-Path $PSScriptRoot '..\scripts\<name>')` | `__TOKEN__` via `-replace` |
| VM templates | `src/vms/templates/` | `Get-Content -Raw` + `.Replace` (Win), `sed` (POSIX) | `__TOKEN__` |
| App configs | `src/modules/configs/` | `ConfigHelpers.ps1`; Nix `home.file` | — |

Windows reads work because `apply.ps1` runs from the live checkout.

## Shared cross-platform content

Same language + same purpose → single shared file. No per-platform duplicates. Shared files in `src/scripts/` (VM: `src/vms/templates/`). Divergence: conditionals or `__TOKEN__` per consumer. Per-platform file only when language/semantics differ; cite at file and consumer.

Registry: `src/scripts/shell/profile.ps1`, `src/scripts/vms/start-android-vm.ps1`, `src/scripts/vms/android-fake-wifi-guest-setup.sh`, `src/scripts/vms/android-fake-wifi-guest-revert.sh`, `src/vms/templates/*`.

## Token convention

`__UPPER_SNAKE__` everywhere (e.g. `__USERNAME__`, `__NIX_INDEX_BIN__`). `{{TOKEN}}` prohibited. Bare uppercase tokens without double underscores are not permitted. Every token replaced by every consumer or documented default. Registry in file header comments. No `__UPPER_SNAKE__` in comments — check step 14 greps. Reference without delimiters (`start-<VM_NAME>.sh`).

Exception: well-known mechanical transformations (`"~"` → home directory, URL percent-encoding, path separator conversion) are not template placeholders.

## Exceptions

Each needs `# check-suppress:embedded-content:`:

1. **Data-driven/generated** — loops, JSON-derived text (vhost blocks, rclone wrapper, PATH snippets, `$virtiofsArgs`, host-kind heredocs).
2. **Trivial static** — under 10 lines (`.cmd` wrapper, README placeholder, ssh/ignore template).
3. **C# interop** — `Add-Type` inline up to 25 lines; beyond → `modules/scripts/*.cs`. **Quarterly (D5)**.
4. **Split-pattern** — static body extracted, dynamic wrapper inline.
5. **DSC `Script` resources** — Get/Test/Set inline (API), 1–3 lines; grow → `modules/scripts/`. **Quarterly (D6)**.

Structured data (git config, sshd_config, wallpaper registry, JSON/INI merge) is NOT file content — passed as parameters, exempt.

## Lint

- `.ps1` under `modules/scripts/`/`src/scripts/` → `scripts/check-pwsh.ps1` (PSScriptAnalyzer).
- `.sh` templates under `src/vms/templates/` → `scripts/check.sh sh`.
- `# check-suppress:` carries from embedded strings to extracted files.
