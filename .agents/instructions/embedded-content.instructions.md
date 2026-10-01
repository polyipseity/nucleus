---
description: "Use when embedding or extracting file content (config templates, profile content, start scripts, wrappers) in Nix, shell, or PowerShell scripts. Covers the no-embedding invariant, shared cross-platform content, token conventions, and documented exceptions."
name: "Embedded Content Policy"
applyTo: "src/**/*.nix, src/**/*.ps1, src/**/*.sh, src/hosts/Windows/**/*.yml, src/scripts/**, src/vms/**, scripts/**"
---

# Embedded content policy

File content (config templates, profile content, start scripts, wrappers, Caddyfiles, READMEs) lives in dedicated files, never in script string literals, on every platform and in every script type. An exception needs `# check-suppress:embedded-content:` at the call site.

## Platform matrix

| Platform | Content location | Read mechanism | Token |
| --- | --- | --- | --- |
| POSIX, Nix eval | `src/scripts/`, `src/modules/configs/` | `builtins.readFile` | `__TOKEN__` via `builtins.replaceStrings` |
| POSIX, sh runtime | adjacent under `src/scripts/` | SCRIPT_DIR-relative (`# shellcheck source=`) | `__TOKEN__` via `sed` |
| Windows, PS runtime | `src/platforms/Windows/modules/scripts/<name>` or shared `src/scripts/` | `Get-Content -Raw (Join-Path $PSScriptRoot '..\scripts\<name>')` | `__TOKEN__` via `-replace` |
| VM templates | `src/vms/templates/` | `Get-Content -Raw` + `.Replace` (Win), `sed` (POSIX) | `__TOKEN__` |
| App configs | `src/modules/configs/` | `ConfigHelpers.ps1`; Nix `home.file` | none |

Windows reads work because `apply.ps1` runs from the live checkout.

## Shared cross-platform content

Same language and same purpose means one shared file, never a per-platform duplicate. Shared files live in `src/scripts/` (VM templates in `src/vms/templates/`); divergence goes in conditionals or per-consumer `__TOKEN__`. A per-platform file is valid only when language or semantics differ, and then the file and every consumer cite the difference.

Registry: `src/scripts/shell/profile.ps1`, `src/scripts/vms/start-android-vm.ps1`, `src/scripts/vms/android-fake-wifi-guest-setup.sh`, `src/scripts/vms/android-fake-wifi-guest-revert.sh`, `src/vms/templates/*`.

## Token convention

`__UPPER_SNAKE__` everywhere, `{{TOKEN}}` prohibited, and bare uppercase without the double markers is not a token. Every token is replaced by every consumer or carries a documented default. The registry lives in file header comments. A `__UPPER_SNAKE__` string in a comment gets rewritten too, so comments never carry one; references appear without the delimiters (`start-<VM_NAME>.sh`).

Well-known mechanical transformations (`"~"` to home directory, URL percent-encoding, path separator conversion) are not template placeholders.

## Exceptions

Each needs `# check-suppress:embedded-content:` at the call site, naming the id:

1. Data-driven or generated: loops and JSON-derived text (vhost blocks, rclone wrapper, PATH snippets, `$virtiofsArgs`, host-kind heredocs).
2. Trivial static, under 10 lines: `.cmd` wrapper, README placeholder, ssh or ignore template.
3. C# interop: `Add-Type` inline up to 25 lines; beyond that it moves to `modules/scripts/*.cs`. Quarterly review (D5).
4. Split pattern: static body extracted, dynamic wrapper inline.
5. DSC `Script` resources: Get/Test/Set inline (API), 1-3 lines; grows into `modules/scripts/`. Quarterly review (D6).

Structured data (git config, sshd_config, wallpaper registry, JSON or INI merge) is not file content: it is passed as parameters and exempt.

## Lint

Check step 02 runs PSScriptAnalyzer over `.ps1` under `modules/scripts/` and `src/scripts/`, and `scripts/check.sh sh` shellchecks `.sh` templates under `src/vms/templates/`. A `# check-suppress:` marker carries from an embedded string to the extracted file.
