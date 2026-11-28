---
description: "Use when creating scripts, tests, or modules that produce console output or logs."
name: "Output and Error Handling"
applyTo: "scripts/**, src/**, tests/**"
alwaysApply: true
---

# Output and error handling

ERROR hard-fails required convergence: POSIX `die`/`error` then `exit 1`, PowerShell `Write-NucleusError` then `throw`. It covers `src/` privilege gaps, activation failures, secrets, hardening, missing Jellyfin token, stale Tier 2 entries, missing preflight tools, and cloud path conflicts. WARNING is skippable work with `# check-suppress:suppression_doc: <reason>`; INFO and NOTICE never report failures. Never downgrade an error, hide it with `|| true`, `2>/dev/null`, or `-ErrorAction SilentlyContinue`, or substitute a default. Each warning or error has disposition `fix`, `upstream`, `by-design`, or `consequence`.

Formats: F1 `[<ts> ]<cmd>: [<level>: ]<msg>` (errors/warnings to stderr); F2 `[step NN]`; F3 `=== [N] <title> ===` with skip reasons; F4 table with check, cross, and en dash; F5 `--json` with integer `"version"` and `--list-*` one entry per line. Use `lib.sh` helpers and `Write-Nucleus*` from `Format-NucleusOutput.psm1`.

Color uses sixteen named colors plus dim and underline via shared helpers; `NO_COLOR` disables, `FORCE_COLOR`/`CLICOLOR_FORCE` enable, and raw ANSI, `tput`, `echo -e`, and `[char]27` are banned outside helpers (step 12). Logs: per-stream `stdout.log` and `stderr.log` under roots from `services.json`; `nucleus-logs` owns rotation, gzip, and 7d expiry (`NUCLEUS_LOG_EXPIRY`). Passthrough categories are in the reference.

Details: `src/users/default/agents/skills/nucleus-policy-reference/references/output-handling.md`.
