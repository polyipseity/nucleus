---
description: "Use when creating or editing scripts, tests, or host modules that produce console output, manage log files, or decide error/warning/info severity. Covers severity decisions, five message formats (F1-F5), console color spec, log storage/rotation, and enforcement."
name: "Output and Error Handling"
applyTo: "scripts/**, src/**, tests/**"
alwaysApply: true
---

# Output and error handling

## Severity decision model

Pick severity by whether the operation must succeed for the host to be correct.

- **ERROR (hard-error):** required convergence/config ops. Abort: POSIX `die`/`error` + `exit 1`; PS1 `Write-NucleusError` + `throw`. Includes: privilege gap on `src/`, inverse-family elevated refusal, activation convergence failure, secrets/identity failure, symlink/ACL hardening failure, Jellyfin admin-token absence, allow/deny-list staleness (Tier 2), missing preflight tool, cloud-drive path conflict.
- **WARNING:** best-effort, safe to skip. Needs `# check-suppress:suppression_doc: reason`. Never `|| true` without reason.
- **INFO / NOTICE:** progress, success, dry-run. Never for failures.

No "warning instead of error because the failure is inconvenient."

### Activation scripts

Hard-error on required convergence failure — `warn` + continue banned. See `activation-scripts.instructions.md`.

### Prohibitions

Never downgrade errors. Never `|| true`/`2>/dev/null`/`-ErrorAction SilentlyContinue` without `# check-suppress:suppression_doc: reason`. Never mask missing values with defaults. Never add fallbacks.

### Disposition

Every warning/error: capture line, classify (`fix`/`upstream`/`by-design`/`consequence`), record evidence. "Benign" without proof = violation.

---

## Message format taxonomy

### F1: Message line

Form: `[<ts> ]<cmd>: [<level>: ]<msg>`. Timestamp optional dim (daemon logs). `<cmd>` = basename minus `.sh`/`nucleus-`. Levels: `notice`, `error`, `warning`, `[dry-run]`; `done` no message. `error`/`warning` → stderr; rest stdout.

POSIX helpers in `src/scripts/lib/lib.sh`: `say`, `notice`, `error`, `warn`, `dry_run`, `nuc_done`, `die`. PS1 `Write-Nucleus*` in `Format-NucleusOutput.psm1`. Help/usage has no `cmd:` prefix.

### F2: Step chrome

`[step NN] <content>` — zero-padded `%2d`, `10#` guard; marker dim, content default; console-only.

### F3: Header/skip markers

`=== [N] <title> ===[ SKIPPED (<reason>)]` — bold cyan, no `cmd:` prefix.

### F4: Tables

Two-space indent; ✓ green / ✗ red / SKIP yellow / ⊘ yellow; dim labels.

### F5: Machine-readable stdout

`--json`: single JSON object/array with INTEGER `"version"` via `jq`/`ConvertTo-Json -Compress`. `--list-*`: one/line, exit 0. Errors to stderr as F1.

---

## Console color spec

Palette: bold/red/yellow/magenta/green/cyan/blue/dim, underline (`4m`), underline-cyan (`4;36m`). 16 named colors only. POSIX vars in lib.sh: `_nuc_c{1,2}_blue`, `_nuc_c{1,2}_underline`, `_nuc_c{1,2}_ulcyan`.

Semantic coloring: URLs → underline-cyan; single-quoted → blue. Quote pass first. Regex-only, no markup delimiters. Applied by `_nuc_semantic_color` (lib.sh) and `ConvertTo-NucleusSemanticColor` (Format-NucleusOutput.psm1).

Detection: `NO_COLOR` non-empty → off (strips all decoration). `FORCE_COLOR` non-0 / `CLICOLOR_FORCE` → on. Else per-stream tty AND `TERM != dumb`. PS1 additionally checks `$Host.UI.SupportsVirtualTerminal` AND `-not [Console]::IsOutputRedirected`. Engine owns `NO_COLOR` → `$PSStyle.OutputRendering = PlainText`; module must NOT mutate it. Color in shared helpers only — no raw ANSI, `tput`, `echo -e` elsewhere (check step 14).

---

## Log storage and rotation

Roots from `services.json` `$logging`: MacBook `~/Library/Application Support/nucleus/logs` + `/Library/Application Support/nucleus/logs`; NixOS `~/.local/share/nucleus/logs` + `/var/lib/nucleus/logs`; Windows `%LOCALAPPDATA%\nucleus\log` + `%ProgramData%\nucleus\log`. Override: `NUCLEUS_LOG_DIR`/`NUCLEUS_SYSTEM_LOG_DIR`. **Every service captures each stream to its own file — `<dir>/stdout.log` and `<dir>/stderr.log`.** Merging the two streams, capturing only one of them, and discarding one to `/dev/null` are prohibited on every host, which is where the platform default would otherwise silently swallow it; unit paths are hardcoded per module and enforced by check step 14 (`repository-policy`). `logging.capture` selects *which* streams are captured (`stderr` means only `stderr.log` exists), never the destination shape, and drives display/rotation/health-check. Rotation: copy-truncate + gzip, 7d expiry, `services.schema.json` defaults (maxSize 1000000, maxFiles 4). Health-check triggers immediate rotation when a file exceeds maxSize.

---

## External exceptions

New passthrough requires spec entry + rationale. Categories: third-party passthrough (nix, brew, cargo, git hooks, winget, adb/qemu), probe suppression, pwsh host rendering, vendored scripts, static doc, bootstrap, VM templates, Nix/Darwin activation scripts, shell-init, framework-local PS1, daemon log writers, test-harness, fixtures, status/diff/event-log, documented third-party (sops, rclone, tart, packer, duperemove, journalctl).

---

## Enforcement

Check step 14 bans raw ANSI/`tput`/`echo -e`/`[char]27`/backtick-e/legacy `==== NN` outside 9-file allowlist: lib.sh, step-runner.sh, step-runner.ps1, test-lib.sh, test-lib.ps1, Format-NucleusOutput.psm1, Format-NucleusOutput.Tests.ps1, Invoke-LogManagement.ps1, log-management.Tests.ps1.
