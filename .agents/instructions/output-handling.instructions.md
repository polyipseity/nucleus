---
description: "Use when creating or editing scripts, tests, or host modules that produce console output, manage log files, or decide error/warning/info severity. Covers severity decisions, five message formats (F1-F5), console color spec, log storage/rotation, and enforcement."
name: "Output and Error Handling"
applyTo: "scripts/**, src/**, tests/**"
alwaysApply: true
---

# Output and error handling

## Severity decision model

Pick severity by whether the operation must succeed for the host to be correct.

- **ERROR (hard-error):** required convergence/config ops — system misconfigured or unsafe without it. Abort with non-zero exit (POSIX `die`/`error` + `exit 1`; PowerShell `Write-NucleusError` + `throw`). Includes: privilege gap on `src/`, inverse-family already-elevated refusal, activation-script convergence failure, secrets/identity derivation failure, symlink/ACL hardening failure, Jellyfin admin-token absence, allow/deny-list staleness (Tier 2), missing required tool in preflight, cloud-drive path conflict.
- **WARNING:** best-effort ops where skipping is safe (daemon restart when not running, cache clear, expected runtime conditions). Still must be checked — never `|| true` without reason. Needs `# check-suppress:suppression_doc: reason`.
- **INFO / NOTICE:** progress, success, dry-run. Never for failures.

No "warning instead of error because the failure is inconvenient."

### Activation scripts

Must hard-error on required convergence failure — `warn` + continue banned. Abort via `die`/`throw`. See `activation-scripts.instructions.md` (`set -euo pipefail`, AC1).

### Prohibitions

- Never downgrade errors to warnings, info, or swallowed failures.
- Never `|| true`, `2>/dev/null`, or `-ErrorAction SilentlyContinue` without `# check-suppress:suppression_doc: reason`.
- Never mask missing/failed values with defaults — surface the failure.
- Never add a fallback when a primary path fails.

### Warning/error disposition

Investigate every warning/error. Capture exact line, classify (`fix` / `upstream` / `by-design` / `consequence`), record evidence. "Benign" without proof violates no-silent-downgrade.

---

## Message format taxonomy

### F1: Message line

Form: `[<ts> ]<cmd>: [<level>: ]<msg>`

- Timestamp: optional `YYYY-MM-DD HH:MM:SS` dim, daemon logs only.
- `<cmd>`: basename — POSIX `basename "$0"` minus `.sh`/`nucleus-`; PS1 `Get-NucleusCommandName -Path`. Override: PS1 `-CommandName`; POSIX `say -l <label>`.
- Levels: `notice`, `error`, `warning`, `[dry-run]`; `done` no message.
- Streams: `error`/`warning` → stderr; rest stdout.
- Colors: cmd bold, error bold red, warning bold yellow, `[dry-run]` bold magenta, done bold green, `[notice]` bold blue, timestamp dim.

POSIX helpers: `say`/`notice`/`error`/`warn`/`dry_run`/`nuc_done`/`die` in `src/scripts/lib/lib.sh`. PS1: `Write-Nucleus*` in `Format-NucleusOutput.psm1`. Help/usage has no `cmd:` prefix.

### F2: Step chrome

`[step NN] <content>` — zero-padded `%2d`, `10#` guard; marker dim, content default; console-only.

### F3: Header/skip markers

`=== [N] <title> ===[ SKIPPED (<reason>)]` — bold cyan, no `cmd:` prefix.

### F4: Tables

Aligned columnar, two-space indent; ✓ green / ✗ red / SKIP yellow / ⊘ yellow; dim labels.

### F5: Machine-readable stdout

No prefixes. `--json` = single JSON object/array with INTEGER `"version"` via `jq` or `ConvertTo-Json -Compress`. `--list-*` = one/line, exit 0. Errors to stderr as F1.

---

## Console color spec

Palette: bold/red/yellow/magenta/green/cyan/blue/dim, underline (`4m`), combined underline-cyan (`4;36m`). Sixteen named colors only. POSIX vars: `_nuc_c{1,2}_blue`, `_nuc_c{1,2}_underline`, `_nuc_c{1,2}_ulcyan` in lib.sh.

### Semantic inline coloring

URLs (`https?://[^ ]*`) → underline-cyan; single-quoted (`'[^']*'`) → blue. Quote pass first. Regex-only — no markup delimiters.

POSIX `_nuc_semantic_color` (lib.sh); PS1 `ConvertTo-NucleusSemanticColor` (Format-NucleusOutput.psm1).

POSIX `_nuc_color_init` (lib.sh): `NO_COLOR` non-empty → off; `FORCE_COLOR` non-0 / `CLICOLOR_FORCE` → on; else per-stream tty AND `TERM != dumb`.

PS1 (`Format-NucleusOutput.psm1` sets `$script:NucleusColorOn`): `FORCE_COLOR`/`CLICOLOR_FORCE` → on; `NO_COLOR` → off; else `$Host.UI.SupportsVirtualTerminal` AND `-not [Console]::IsOutputRedirected`. Engine owns `NO_COLOR` → `$PSStyle.OutputRendering = PlainText`; module must NOT mutate it.

Console-only: color in shared helpers only — no raw ANSI, `tput`, `echo -e` elsewhere (check step 14).

---

## Log storage and rotation

Roots from `services.json` `$logging`: MacBook `~/nucleus/logs` + `/Users/Shared/nucleus/logs` (SIP); NixOS `~/.local/state/nucleus/log` + `/var/log/nucleus`; Windows `%LOCALAPPDATA%\nucleus\logs` + `%ProgramData%\nucleus\logs`. Override: `NUCLEUS_LOG_DIR`/`NUCLEUS_SYSTEM_LOG_DIR`.

Unit output paths hardcoded per-module; `logging.capture` configures display/rotation/health-check, not output paths.

Rotation: copy-truncate + gzip; `NUCLEUS_GC_EXPIRY` default 7d; defaults from `services.schema.json` (maxSize 10000000, maxFiles 4, compress true, sanitize true); NixOS daily 12:00 timer.

---

## External exceptions

Bypassing output classes (new passthrough needs spec entry + one-line rationale): third-party passthrough (nix, brew, cargo, git hooks, winget, adb/qemu), probe suppression (vm.sh, ai.sh), pwsh host rendering, vendored scripts, static doc, bootstrap, VM guest templates, Nix-inlined activation, Darwin activation (env -i wipes color), shell-init, framework-local PS1, daemon log writers, test-harness, fixtures, status/diff/event-log, documented third-party (sops, rclone, tart, packer, duperemove, journalctl).

---

## Enforcement

Check step 14 bans raw ANSI/`tput`/`echo -e`/`[char]27`/backtick-e/legacy `==== NN` outside 9-file allowlist: lib.sh, step-runner.sh, step-runner.ps1, test-lib.sh, test-lib.ps1, Format-NucleusOutput.psm1, Format-NucleusOutput.Tests.ps1, Invoke-LogManagement.ps1, log-management.Tests.ps1. NO_COLOR self-checks in lib.sh and Format-NucleusOutput.psm1.
