---
description: "Use when creating or editing scripts, tests, or host modules that produce console output or manage log files. Covers the five message formats (F1-F5), console color spec and detection, log storage/rotation, external exceptions, and check step 14 enforcement."
name: "Logging and Output Format"
applyTo: "scripts/**/*.sh, scripts/**/*.ps1, src/scripts/**/*.sh, src/scripts/**/*.ps1, src/platforms/Windows/modules/**/*.ps1, src/hosts/Windows/**/*.ps1, src/hosts/MacBook/**/*.nix, src/hosts/NixOS/**/*.nix, src/vms/**/*.sh, tests/**, src/modules/logging.nix"
---

# Logging and output format standard

This document is the canonical contract for all console output and log files produced by `nucleus-*` commands, internal scripts, and host modules. Five message formats (F1-F5) cover every output class; the console color spec governs when colors apply; check step 14 enforces the console-only invariant. POSIX helpers live in `src/scripts/lib/lib.sh` (messages, colors), `src/scripts/lib/step-runner.sh` and `src/scripts/tests/test-lib.sh` (pipeline chrome); PowerShell equivalents live in `src/platforms/Windows/modules/Format-NucleusOutput.psm1`, `src/scripts/lib/step-runner.ps1` and `src/scripts/tests/test-lib.ps1`.

## F1: Message line

Every human-readable message uses the form `[<ts> ]<cmd>: [<level>: ]<msg>`.

- Timestamp: optional `YYYY-MM-DD HH:MM:SS` dim prefix, emitted by daemon logs only; log files hold F1 timestamped lines plain.
- `<cmd>`: command basename — POSIX `basename "$0"` minus `.sh`/`nucleus-`; PS1 `Get-NucleusCommandName -Path`. Overridable via label override: PS1 `-CommandName` parameter on `Write-Nucleus*` helpers; POSIX `say -l <label>`.
- Levels: `notice`, `error`, `warning`, `[dry-run]`; `done` is fixed with no message.
- Streams: `error`/`warning` → stderr; all else stdout.
- Colors (console only): cmd bold, error bold red, warning bold yellow, `[dry-run]` bold magenta, done bold green, `[notice]` bold blue, timestamp dim.

Helpers: POSIX `say`/`notice`/`error`/`warn`/`dry_run`/`nuc_done`/`die` in `src/scripts/lib/lib.sh`; PS1 `Write-NucleusInfo`/`Write-NucleusNotice`/`Write-NucleusError`/`Write-NucleusWarning`/`Write-NucleusDryRun`/`Write-NucleusDone` in `Format-NucleusOutput.psm1`. Help/usage output (stdout docs) has no `cmd:` prefix by design.

## F2: Step chrome

`[step NN] <content>` — NN zero-padded `%2d` with a `10#` octal guard; marker dim, content default; console-only (capture files plain).

## F3: Header and skip markers

`=== [N] <title> ===[ SKIPPED (<reason>)]` — bold cyan. Skip markers are emitted by the shared `skip_step` helper (`step-runner.sh`/`step-runner.ps1`) with NO `cmd:` prefix; the runner's own `_run_skipped_step`/`Invoke-SkippedStep` already emit this form.

## F4: Tables

Aligned columnar rows with two-space indent; glyphs ✓ green / ✗ red / SKIP yellow / ⊘ yellow; dim labels. ⊘ emitters: `tests/scripts/gen-completions-tests.sh` (lines 15-18) and `tests/scripts/nucleus-apps-smoke-tests.sh` (lines 23-26), via the YELLOW var in `tests/scripts/test-lib.sh`.

## F5: Machine-readable stdout

Pure data, no prefixes. `--json` = a single JSON object/array with an INTEGER `"version"`, built via `jq` (POSIX) or `ConvertTo-Json -Compress` (PS1) — never hand-concatenated. `--list-*` = one value per line, exit 0. Errors go to stderr as F1.

## Console color spec

Palette: bold/red/yellow/magenta/green/cyan/blue/dim, underline (`4m` / `$PSStyle.Underline`), and combined underline-cyan (`4;36m`, used for URLs). Sixteen named colors only — parity with `$PSStyle.Foreground`'s 16 names; no bright or 256-color variants. POSIX vars: `_nuc_c{1,2}_blue`, `_nuc_c{1,2}_underline`, `_nuc_c{1,2}_ulcyan` in `src/scripts/lib/lib.sh`.

### Semantic inline coloring

Message helpers tokenize message text before emitting. URL spans (`https?://[^ ]*`) render underline-cyan; single-quoted spans (`'[^']*'`) render blue. The quote pass runs first so a URL inside quotes still reads as a URL.

- Color-on only: when the stream color is off, output is byte-identical plain.
- Zero markup delimiters in the regex language — backtick-delimited markup is banned (backticks would trigger shell command substitution inside double-quoted `printf` call sites). Regex-only.
- Applied by `say`/`notice`/`error`/`warn`/`dry_run` (POSIX `_nuc_semantic_color` in `src/scripts/lib/lib.sh`) and `Write-NucleusInfo`/`Write-NucleusNotice`/`Write-NucleusError`/`Write-NucleusWarning`/`Write-NucleusDryRun`/`Write-NucleusDone` (PS1 `ConvertTo-NucleusSemanticColor` in `Format-NucleusOutput.psm1`).

POSIX detection (POSIX-sh, `_nuc_color_init` in `src/scripts/lib/lib.sh`):

- `NO_COLOR` set non-empty → off on both streams (strips ALL decoration incl. bold — deliberate superset).
- Else `FORCE_COLOR` set and not 0, or `CLICOLOR_FORCE` set non-empty → on.
- Else per-stream `[ -t 1 ]`/`[ -t 2 ]` AND `TERM != dumb`.

PS1 (`$PSStyle` escapes embedded by `Format-NucleusOutput.psm1` only when the one-time `$script:NucleusColorOn` flag is set, computed at import):

- `FORCE_COLOR` set and not 0 / `CLICOLOR_FORCE` set → on.
- `NO_COLOR` set → off.
- Else `$Host.UI.SupportsVirtualTerminal` AND `-not [Console]::IsOutputRedirected`.
- The engine owns `NO_COLOR` → `$PSStyle.OutputRendering = PlainText`; the module must NOT mutate `$PSStyle.OutputRendering`.
- `$PSStyle.Foreground` has only 16 named colors; `Bold`/`Dim` are top-level members (7.4+).

Console-only invariant: color lives inside shared helpers only (lib.sh, Format-NucleusOutput.psm1, step-runner, test-lib) — no raw ANSI (`\033[`/`\e[`/`\x1b[`), `tput`, or `echo -e` elsewhere, enforced by check step 14.

## Log storage and rotation

Roots per host from `src/modules/services.json` `$logging`: MacBook `~/nucleus/logs` + `/Users/Shared/nucleus/logs` (SIP); NixOS `~/.local/state/nucleus/log` + `/var/log/nucleus`; Windows `%LOCALAPPDATA%\nucleus\logs` + `%ProgramData%\nucleus\logs`; overrides `NUCLEUS_LOG_DIR`/`NUCLEUS_SYSTEM_LOG_DIR`.

Files hold F1 timestamped lines plain. Unit output paths are hardcoded per-module (launchd `StandardOutPath`/`StandardErrorPath`, `/dev/null` for silent daemons); NixOS journald. `logging.capture` configures display/rotation/health-check behavior, NOT unit output paths.

Rotation: `log-gc-user.sh`/`log-gc-system.sh` copy-truncate + gzip; `NUCLEUS_GC_EXPIRY` default 7d; defaults from `src/modules/services.schema.json` `definitions.loggingEntry.properties` (maxSize 10000000, maxFiles 4, compress true, sanitize true); NixOS daily 12:00 timer.

## External exceptions

These output classes intentionally bypass the standard; new passthrough requires a spec entry with a one-line rationale — never silently added or removed.

- Third-party passthrough: nix/darwin-rebuild/home-manager build output, brew/cargo/bun/uv/rustup/ollama, git hook prek/commitlint/treefmt, winget configure, adb/qemu VM output.
- Probe suppression: vm.sh virsh/socat/ssh/adb/tart readiness, ai.sh ollama readiness, silent-daemon `/dev/null`.
- pwsh host rendering: `WARNING: ` prefix and `Write-Error` rendering are host-injected.
- Vendored `vendor/` scripts untouched.
- Static doc content: MANUAL.md activation tail, `--- MANUAL SETUP (one-time, required) ---` banner in apply.ps1, `# ---- name ----` activation separators in macOS activation.nix.
- Pre-lib bootstrap lines: apply.sh root check (line 9).
- VM guest templates (POSIX + PS1): `vm-setup:` / `nucleus-vm:` labels — rendered templates; lib.sh / module unavailable in the guest.
- Android guest script: `virt_wifi:` — same rendered/guest context.
- Nix-inlined activation scripts: `lib/symlink-hardening.sh`, `lib/symlink-convergence.sh`, `services/cloud-drives-setup.sh` — literal context labels; lib.sh unreachable via `builtins.readFile` / activationScripts.
- Shell-init contexts: `src/scripts/shell/init.zsh`, `src/scripts/shell/profile.ps1`, `src/platforms/macOS/scripts/macos-install-icloud-hooks.zsh` — F1 literal grammar; no helpers (lib.sh / module import unavailable in shell-init).
- Framework-local PS1: `src/scripts/lib/nix-test-eval.ps1` — `test: error:` literals already F1 grammar; no module import in the test-framework context.
- Daemon log-file writers: `service-watchdog.sh` / `service-watchdog.ps1` — `[<ts>] watchdog: ...` F1-shaped lines written to log files (trap context + file writers, not console).
- Test-harness summary markers: `FAIL:`, `PASS:`, `Testing:`, `ERROR:` in test result files.
- `tests/fixtures/logging-format` scope exclusion — fixture files intentionally exempt from the logging-format check.
- Status/diff/event-log displays: `scripts/ai.ps1` Endpoints status table, `src/scripts/completions/gen-completions.ps1` diff output, `scripts/svc.ps1` event log, `step-runner.ps1:196` ERROR passthrough — verbatim status/diff lines, not F1 messages.
- Third-party additions (documented, not silenced): `sops updatekeys`, `rclone sync` stats, `tart`/`virsh`/`utmctl` console, `packer`/`nixos-generators`, `duperemove`, `journalctl` svc logs, `nix flake update`.

## Enforcement

Check step 14 (`src/scripts/checks/check-steps/14-repository-policy.{sh,ps1}` + `repository-policy.awk` logging-format mode) bans raw ANSI/`tput`/`echo -e`/`[char]27`/backtick-e/legacy `==== NN` markers outside a 9-file allowlist: lib.sh, step-runner.sh, step-runner.ps1, test-lib.sh, test-lib.ps1, Format-NucleusOutput.psm1, Format-NucleusOutput.Tests.ps1, Invoke-LogManagement.ps1, log-management.Tests.ps1; plus self-checks for NO_COLOR presence in lib.sh and Format-NucleusOutput.psm1.

The awk leaf-match allowlist `(^|\/)(lib|step-runner|test-lib)\.(sh|ps1)$` over-allows a hypothetical `lib.ps1` (no such file exists today); the over-allowance is accepted as future-proofing for a `lib.ps1` module leaf — the awk is not changed.

## Related instruction files

- `step-runner.instructions.md` — step chrome (F2) and skip markers (F3) in the check/test pipelines.
- `tooling-and-validation.instructions.md` — check step taxonomy and preflight policy.
