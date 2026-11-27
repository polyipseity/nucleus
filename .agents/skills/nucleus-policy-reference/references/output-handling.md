---
description: "Use when creating scripts, tests, or modules that produce console output or logs."
name: "Output and Error Handling"
applyTo: "scripts/**, src/**, tests/**"
alwaysApply: true
---

# Output and error handling

Severity depends on whether the host is correct without the operation. ERROR hard-fails required convergence or config work: POSIX `die`/`error` then `exit 1`, PowerShell `Write-NucleusError` then `throw`. It covers `src/` privilege gaps, inverse-family elevated runs, activation convergence, secrets and identity, symlink and ACL hardening, missing Jellyfin admin token, stale Tier 2 allow or deny entries, missing preflight tools, and cloud-drive path conflicts. Activation never warns past a required failure.

WARNING is best-effort work safe to skip and needs `# check-suppress:suppression_doc: <reason>`. INFO and NOTICE cover progress, success, and dry runs, never failures. Never downgrade an error because it is inconvenient, never `|| true`, `2>/dev/null`, or `-ErrorAction SilentlyContinue` without annotation, and never substitute a default for a missing or failed value. Every warning and error has a disposition: `fix`, `upstream`, `by-design`, or `consequence`, with the evidence line.

## Message formats

F1: `[<ts> ]<cmd>: [<level>: ]<msg>`; timestamp optional and dim, `<cmd>` basename without `.sh` or `nucleus-`. Levels `notice`, `error`, `warning`, `[dry-run]`; `done` prints nothing. Errors and warnings go to stderr, others stdout. Helpers: `say`, `notice`, `error`, `warn`, `dry_run`, `nuc_done`, `die` in `src/scripts/lib/lib.sh`, and `Write-Nucleus*` in `Format-NucleusOutput.psm1`. Help and usage text has no `cmd:` prefix.

F2 step chrome `[step NN] <content>`, two-digit zero padding with `10#` guard, dim marker, console only. F3 header `=== [N] <title> ===`, bold cyan, no prefix, with `not applicable (<reason>)` or `not-selected` appended when skipped. F4 table: two-space indent, green check, red cross, yellow en dash for not applicable or not selected, dim labels. F5 `--json` emits one JSON object or array with integer `"version"` via `jq` or `ConvertTo-Json -Compress`; `--list-*` emits one entry per line and exits 0; errors stay on stderr as F1.

## Color and logs

Sixteen named colors plus dim, underline (`4m`), underline-cyan (`4;36m`). Semantic coloring runs after the quote pass: URLs underline-cyan, single-quoted spans blue, regex only with no markup delimiters. POSIX `_nuc_semantic_color` in `lib.sh`, PowerShell `ConvertTo-NucleusSemanticColor` in `Format-NucleusOutput.psm1`.

Non-empty `NO_COLOR` disables decoration; `FORCE_COLOR` other than `0` or `CLICOLOR_FORCE` enables it; otherwise per-stream tty and `TERM != dumb`. PowerShell also needs `$Host.UI.SupportsVirtualTerminal` and `-not [Console]::IsOutputRedirected`. The engine owns `NO_COLOR` and sets `$PSStyle.OutputRendering = PlainText`; the output module must not mutate it. Color lives only in shared helpers; step 12 `repository-policy.awk` in logging-format mode fails raw ANSI, `tput`, `echo -e`, `[char]27`, and backtick-e escapes outside the helper allowlist.

Log roots come from `services.json` `$logging`, overridable with `NUCLEUS_LOG_DIR` and `NUCLEUS_SYSTEM_LOG_DIR`; NixOS services use journald. macOS and Windows capture each stream separately as `<dir>/stdout.log` and `<dir>/stderr.log`. Where captured, merging streams, dropping one, or discarding to `/dev/null` is prohibited; step 12 enforces the pair. `logging.capture` selects which streams are captured and drives display, rotation, and health-check, never destination shape.

`nucleus-logs` owns rotation and expiry for every nucleus log, even files written directly by native writers. Rotation copy-truncates each `*.log` under a managed root, compresses with gzip when `compress` is true (`--max-files 0` truncates without archiving), expires archives after 7d by default (`NUCLEUS_LOG_EXPIRY`), and takes thresholds from `services.schema.json` `$logging`. Health-check rotates immediately past `maxSize`.

Sanctioned passthrough categories: third-party tools (nix, brew, cargo, git hooks, winget, adb, qemu), probe suppression, pwsh host rendering, vendored scripts, static doc, bootstrap, VM templates, Nix and Darwin activation, shell-init, framework-local PS1, daemon log writers, test harness, fixtures, status/diff/event-log, and documented tools (sops, rclone, tart, packer, duperemove, journalctl).
