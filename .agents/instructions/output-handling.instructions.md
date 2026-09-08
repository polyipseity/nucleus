---
description: "Use when creating or editing scripts, tests, or host modules that produce console output, manage log files, or decide error/warning/info severity. Covers severity decisions, five message formats (F1-F5), console color spec, log storage/rotation, and enforcement."
name: "Output and Error Handling"
applyTo: "scripts/**, src/**, tests/**"
alwaysApply: true
---

# Output and error handling

## Severity decision model

Pick severity by whether the operation must succeed for the host to be correct.

- **ERROR (hard-error):** required convergence/config ops — failure means the system is misconfigured or unsafe. Abort with non-zero exit (POSIX `die`/`error` + `exit 1`; PowerShell `Write-NucleusError` + `throw`). Includes: privilege gap on `src/`, inverse-family already-elevated refusal, activation-script convergence failure, secrets/identity derivation failure, symlink/ACL hardening failure, Jellyfin admin-token absence, allow/deny-list staleness (Tier 2), missing required tool in preflight, cloud-drive path conflict.
- **WARNING:** best-effort ops where skipping is safe (daemon restart when not running, cache clear, expected runtime conditions, post-apply step with absent prerequisite). Still must be checked — never `|| true` without reason. Every warning needs `# check-suppress:suppression_doc: reason`.
- **INFO / NOTICE:** normal progress, success, dry-run. Never for failures.

If the op must succeed for the host to be correct → error. If it is optional and safe to skip → warning with justification. No "warning instead of error because the failure is inconvenient."

### Activation scripts hard-error

Activation scripts must hard-error on required convergence failure — `warn` + continue is banned. Abort via `die`/`throw`. See `activation-scripts.instructions.md` (`set -euo pipefail`, AC1).

### Prohibitions

- Never downgrade an error to a warning, info, or swallowed failure.
- Never `|| true`, `2>/dev/null`, or `-ErrorAction SilentlyContinue` without `# check-suppress:suppression_doc: reason`.
- Never mask a missing/failed value with a default (`or ""`, `?? ""`, `dict.get(k, "")`, etc.) — surface the failure.
- Never add a fallback when a primary path fails.

### Warning/error disposition

Every warning/error must be investigated. Capture the exact line, classify (`fix` / `upstream` / `by-design` / `consequence`), and record evidence. "Benign" without proof violates the no-silent-downgrade rule.

---

## Message format taxonomy

### F1: Message line

Form: `[<ts> ]<cmd>: [<level>: ]<msg>`

- Timestamp: optional `YYYY-MM-DD HH:MM:SS` dim prefix, daemon logs only.
- `<cmd>`: command basename — POSIX `basename "$0"` minus `.sh`/`nucleus-`; PS1 `Get-NucleusCommandName -Path`. Overridable: PS1 `-CommandName`; POSIX `say -l <label>`.
- Levels: `notice`, `error`, `warning`, `[dry-run]`; `done` is fixed with no message.
- Streams: `error`/`warning` → stderr; all else stdout.
- Colors: cmd bold, error bold red, warning bold yellow, `[dry-run]` bold magenta, done bold green, `[notice]` bold blue, timestamp dim.

Helpers: POSIX `say`/`notice`/`error`/`warn`/`dry_run`/`nuc_done`/`die` in `src/scripts/lib/lib.sh`; PS1 `Write-Nucleus*` in `Format-NucleusOutput.psm1`. Help/usage output has no `cmd:` prefix.

### F2: Step chrome

`[step NN] <content>` — NN zero-padded `%2d` with `10#` octal guard; marker dim, content default; console-only.

### F3: Header and skip markers

`=== [N] <title> ===[ SKIPPED (<reason>)]` — bold cyan. No `cmd:` prefix.

### F4: Tables

Aligned columnar rows, two-space indent; ✓ green / ✗ red / SKIP yellow / ⊘ yellow; dim labels.

### F5: Machine-readable stdout

Pure data, no prefixes. `--json` = single JSON object/array with INTEGER `"version"`, built via `jq` (POSIX) or `ConvertTo-Json -Compress` (PS1). `--list-*` = one value per line, exit 0. Errors to stderr as F1.

---

## Console color spec

Palette: bold/red/yellow/magenta/green/cyan/blue/dim, underline (`4m` / `$PSStyle.Underline`), combined underline-cyan (`4;36m`, URLs). Sixteen named colors only — parity with `$PSStyle.Foreground`. POSIX vars: `_nuc_c{1,2}_blue`, `_nuc_c{1,2}_underline`, `_nuc_c{1,2}_ulcyan` in `src/scripts/lib/lib.sh`.

### Semantic inline coloring

URLs (`https?://[^ ]*`) → underline-cyan; single-quoted spans (`'[^']*'`) → blue. Quote pass first so URL inside quotes still shows. Zero markup delimiters — regex-only, backtick-delimited markup banned.

Applied by POSIX `_nuc_semantic_color` (lib.sh) and PS1 `ConvertTo-NucleusSemanticColor` (Format-NucleusOutput.psm1).

POSIX detection (`_nuc_color_init` in lib.sh):
- `NO_COLOR` non-empty → off (strips all decoration incl. bold)
- `FORCE_COLOR` non-0 or `CLICOLOR_FORCE` non-empty → on
- Else per-stream tty AND `TERM != dumb`

PS1 (`$PSStyle` escapes by Format-NucleusOutput.psm1 when `$script:NucleusColorOn` set):
- `FORCE_COLOR` non-0 / `CLICOLOR_FORCE` → on; `NO_COLOR` → off
- Else `$Host.UI.SupportsVirtualTerminal` AND `-not [Console]::IsOutputRedirected`
- Engine owns `NO_COLOR` → `$PSStyle.OutputRendering = PlainText`; module must NOT mutate it

Console-only: color lives in shared helpers only — no raw ANSI, `tput`, or `echo -e` elsewhere (enforced by check step 14).

---

## Log storage and rotation

Roots from `src/modules/services.json` `$logging`: MacBook `~/nucleus/logs` + `/Users/Shared/nucleus/logs` (SIP); NixOS `~/.local/state/nucleus/log` + `/var/log/nucleus`; Windows `%LOCALAPPDATA%\nucleus\logs` + `%ProgramData%\nucleus\logs`. Override: `NUCLEUS_LOG_DIR`/`NUCLEUS_SYSTEM_LOG_DIR`.

Unit output paths hardcoded per-module; `logging.capture` configures display/rotation/health-check, not unit output paths.

Rotation: `log-gc-user.sh`/`log-gc-system.sh` copy-truncate + gzip; `NUCLEUS_GC_EXPIRY` default 7d; defaults from `services.schema.json` `definitions.loggingEntry.properties` (maxSize 10000000, maxFiles 4, compress true, sanitize true); NixOS daily 12:00 timer.

---

## External exceptions

Output classes bypassing the standard (new passthrough needs a spec entry with one-line rationale): third-party passthrough (nix, brew, cargo, git hooks, winget, adb/qemu), probe suppression (vm.sh, ai.sh readiness), pwsh host rendering, vendored scripts, static doc content, bootstrap lines, VM guest templates, Nix-inlined activation scripts, Darwin activation scripts (env -i wipes color), shell-init contexts, framework-local PS1, daemon log writers, test-harness markers, fixture files, status/diff/event-log displays, documented third-party additions (sops, rclone, tart, packer, duperemove, journalctl).

---

## Enforcement

Check step 14 bans raw ANSI/`tput`/`echo -e`/`[char]27`/backtick-e/legacy `==== NN` markers outside a 9-file allowlist: lib.sh, step-runner.sh, step-runner.ps1, test-lib.sh, test-lib.ps1, Format-NucleusOutput.psm1, Format-NucleusOutput.Tests.ps1, Invoke-LogManagement.ps1, log-management.Tests.ps1; plus NO_COLOR self-checks in lib.sh and Format-NucleusOutput.psm1.
