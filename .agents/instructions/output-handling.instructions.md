---
description: "Use when creating or editing scripts, tests, or host modules that produce console output, manage log files, or decide error/warning/info severity. Covers severity decisions, five message formats (F1-F5), console color spec, log storage/rotation, and enforcement."
name: "Output and Error Handling"
applyTo: "scripts/**, src/**, tests/**"
alwaysApply: true
---

# Output and error handling

## Severity

Severity depends on whether the host is correct without the operation.

ERROR hard-fails: required convergence or config work. POSIX `die`/`error` then `exit 1`, PowerShell `Write-NucleusError` then `throw`. It covers a privilege gap in `src/`, an inverse-family script refusing to run elevated, activation convergence failure, secrets or identity failure, symlink and ACL hardening failure, a missing Jellyfin admin token, a stale Tier 2 allow or deny list entry, a missing preflight tool, and a cloud-drive path conflict. Activation scripts never `warn` past a required convergence failure.

WARNING is for best-effort work that is safe to skip, and needs `# check-suppress:suppression_doc: <reason>`. INFO and NOTICE cover progress, success, and dry runs, never failures.

Never downgrade an error because the failure is inconvenient. Never `|| true`, `2>/dev/null`, or `-ErrorAction SilentlyContinue` without that annotation. Never substitute a default for a missing or failed value, and never add a fallback path.

Every warning and error needs a disposition: `fix`, `upstream`, `by-design`, or `consequence`, with the evidence line. "Benign" without proof is a violation.

## Message formats

F1 message line: `[<ts> ]<cmd>: [<level>: ]<msg>`, timestamp optional and dim. `<cmd>` is the basename minus `.sh` or `nucleus-`. Levels are `notice`, `error`, `warning`, and `[dry-run]`; `done` prints no message. `error` and `warning` go to stderr, the rest to stdout. Helpers: `say`, `notice`, `error`, `warn`, `dry_run`, `nuc_done`, `die` in `src/scripts/lib/lib.sh`, and `Write-Nucleus*` in `Format-NucleusOutput.psm1`. Help and usage text carries no `cmd:` prefix.

F2 step chrome: `[step NN] <content>`, zero-padded to two digits with a `10#` guard, marker dim, content in the default color, console only.

F3 header marker: `=== [N] <title> ===`, bold cyan, no `cmd:` prefix. A step that does not run appends `not applicable (<reason>)` or `not-selected`.

F4 table: two-space indent, green check, red cross, and a yellow en dash for not applicable or not selected, with dim labels.

F5 machine-readable stdout: `--json` emits one JSON object or array with an integer `"version"` via `jq` or `ConvertTo-Json -Compress`, `--list-*` emits one entry per line and exits 0, and errors still go to stderr as F1.

## Console color

Sixteen named colors only, plus dim, underline (`4m`), and underline-cyan (`4;36m`). Semantic coloring runs after the quote pass: URLs get underline-cyan, single-quoted spans get blue. Regex only, no markup delimiters. POSIX uses `_nuc_semantic_color` in `lib.sh`, PowerShell `ConvertTo-NucleusSemanticColor` in `Format-NucleusOutput.psm1`.

A non-empty `NO_COLOR` turns decoration off. `FORCE_COLOR` set to anything but 0, or `CLICOLOR_FORCE`, turns it on. Otherwise it follows per-stream tty and `TERM != dumb`. PowerShell also requires `$Host.UI.SupportsVirtualTerminal` and `-not [Console]::IsOutputRedirected`. The engine owns `NO_COLOR` and sets `$PSStyle.OutputRendering = PlainText`; the output module must not mutate it.

Color lives in the shared helpers only. `repository-policy.awk` in logging-format mode, run by check step 12, fails raw ANSI literals, `tput`, `echo -e`, `[char]27`, and backtick-e everywhere outside its own color-helper allowlist.

## Log storage and rotation

Roots come from `services.json` `$logging` and are overridable with `NUCLEUS_LOG_DIR` and `NUCLEUS_SYSTEM_LOG_DIR`. NixOS services log to journald. macOS and Windows capture each stream to its own file, `<dir>/stdout.log` and `<dir>/stderr.log`.

Where a file is captured, merging the two streams, capturing one and dropping the other, and discarding a stream to `/dev/null` are all prohibited: the platform default would swallow it silently. Unit paths are hardcoded per module and check step 12 enforces the pair. `logging.capture` selects which streams are captured, never the destination shape, and drives display, rotation, and health-check.

Rotation is copy-truncate plus gzip, 7d expiry, with thresholds from the `services.schema.json` `$logging` defaults. Health-check rotates immediately when a file passes `maxSize`.

Sanctioned passthrough categories, for output that is not a nucleus message: third-party passthrough (nix, brew, cargo, git hooks, winget, adb, qemu), probe suppression, pwsh host rendering, vendored scripts, static doc, bootstrap, VM templates, Nix and Darwin activation scripts, shell-init, framework-local PS1, daemon log writers, test harness, fixtures, status/diff/event-log, and documented third-party tools (sops, rclone, tart, packer, duperemove, journalctl).
