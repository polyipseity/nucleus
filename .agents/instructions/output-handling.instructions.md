---
description: "Use when creating or editing scripts, tests, or host modules that produce console output, manage log files, or decide error/warning/info severity. Covers severity decisions, five message formats (F1-F5), console color spec, log storage/rotation, and enforcement."
name: "Output and Error Handling"
applyTo: "scripts/**, src/**, tests/**"
alwaysApply: true
---

# Output and error handling

This file covers both **when** to choose a severity level (error/warning/info) and **how** to format/emit messages. The severity decision model decides which level a given operation earns; the format taxonomy defines how messages appear.

## Severity decision model

Select severity by whether the operation must succeed for the host to be correct.

- **ERROR (hard-error):** any required convergence or configuration operation whose failure means the system is misconfigured or unsafe. Surface it with a non-zero exit (POSIX `die`/`error` + `exit 1`; PowerShell `Write-NucleusError` + `throw`). Continuing past it is forbidden. Includes:
  - Privilege gap on `src/` code (see `scripts-and-permissions.instructions.md`, rule 1).
  - Inverse-family already-elevated refusal (see `scripts-and-permissions.instructions.md`, rule 3 — a hard refusal, not a warning).
  - Activation-script convergence failure (see below).
  - Secrets/identity derivation failure (age-key, GPG ownertrust, SSH fingerprint manifest).
  - Symlink creation / ACL delete-protection hardening failure.
  - Jellyfin admin-token absence (see `scripts-and-permissions.instructions.md`, Jellyfin note).
  - Allow/deny-list staleness (see `allow-and-deny-lists.instructions.md`, Tier 2).
  - Missing required tool in check/test preflight (see `tooling-and-validation.instructions.md`).
  - Cloud-drive mount/replica path conflict (see `cloud-drives-and-finder.instructions.md`).
- **WARNING (continue allowed):** optional or best-effort operations where skipping is safe — daemon restart when not yet running, cache clear, an expected runtime condition (e.g. `bootout` on an absent service, see `macos-service-hardening.instructions.md` M1/M2), or a by-design post-apply step whose prerequisite is absent. A warning still must be checked — never `|| true` without reason. Every warning requires an inline or preceding-line `# check-suppress:suppression_doc: reason` comment (see `maintain.instructions.md` MA1 and `comment-annotations.instructions.md` CA1/CA2).
- **INFO / NOTICE:** normal progress, success, or dry-run. Never used to report a failure.

If the operation must succeed for the host to be correct, it is an error. If it is nice-to-have and safe to skip, it is a warning with justification. There is no "warning instead of error because the failure is inconvenient" category.

### Activation scripts hard-error

Activation scripts run during system configuration apply (nix-darwin `darwin-rebuild`, Home Manager, `nixos-rebuild`, Windows DSC/`apply.ps1`). They must hard-error on any required convergence failure — `warn`/`Write-NucleusWarning` + continue is banned for required operations. A required op that fails must abort via `die`/`throw`, not downgrade to a warning. See `activation-scripts.instructions.md` (`set -euo pipefail`, AC1) for the activation script baseline.

### Do not

- Never downgrade an error to a warning, info log, or silently swallowed failure.
- Never use `|| true`, `2>/dev/null`, or `-ErrorAction SilentlyContinue` without a `# check-suppress:suppression_doc: reason` comment.
- Never mask a missing or failed value with a default (`or ""`, `?? ""`, `|| ""`, `dict.get(k, "")`, `-ErrorAction SilentlyContinue` without stated reason) — surface the failure.
- Never add a fallback path or silent default when a primary path fails.

### Disposition of every warning/error

Never leave a warning/error uninvestigated. For each emitted item: capture the exact line, classify it (`fix` / `upstream` / `by-design` / `consequence`), and record the evidence behind the classification. "Benign" without proof — a confirmed-running service, an intentional flag, a named upstream bug, or a documented condition — violates the no-silent-downgrade rule.

---

## Message format taxonomy

### F1: Message line

Every human-readable message uses the form `[<ts> ]<cmd>: [<level>: ]<msg>`.

- Timestamp: optional `YYYY-MM-DD HH:MM:SS` dim prefix, emitted by daemon logs only; log files hold F1 timestamped lines plain.
- `<cmd>`: command basename — POSIX `basename "$0"` minus `.sh`/`nucleus-`; PS1 `Get-NucleusCommandName -Path`. Overridable via label override: PS1 `-CommandName` parameter on `Write-Nucleus*` helpers; POSIX `say -l <label>`.
- Levels: `notice`, `error`, `warning`, `[dry-run]`; `done` is fixed with no message.
- Streams: `error`/`warning` → stderr; all else stdout.
- Colors (console only): cmd bold, error bold red, warning bold yellow, `[dry-run]` bold magenta, done bold green, `[notice]` bold blue, timestamp dim.

Helpers: POSIX `say`/`notice`/`error`/`warn`/`dry_run`/`nuc_done`/`die` in `src/scripts/lib/lib.sh`; PS1 `Write-NucleusInfo`/`Write-NucleusNotice`/`Write-NucleusError`/`Write-NucleusWarning`/`Write-NucleusDryRun`/`Write-NucleusDone` in `Format-NucleusOutput.psm1`. Help/usage output (stdout docs) has no `cmd:` prefix by design.

### F2: Step chrome

`[step NN] <content>` — NN zero-padded `%2d` with a `10#` octal guard; marker dim, content default; console-only (capture files plain).

### F3: Header and skip markers

`=== [N] <title> ===[ SKIPPED (<reason>)]` — bold cyan. Skip markers are emitted by the shared `skip_step` helper (`step-runner.sh`/`step-runner.ps1`) with NO `cmd:` prefix; the runner's own `_run_skipped_step`/`Invoke-SkippedStep` already emit this form.

### F4: Tables

Aligned columnar rows with two-space indent; glyphs ✓ green / ✗ red / SKIP yellow / ⊘ yellow; dim labels. ⊘ emitters: `tests/scripts/gen-completions-tests.sh` (lines 15-18) and `tests/scripts/nucleus-apps-smoke-tests.sh` (lines 23-26), via the YELLOW var in `tests/scripts/test-lib.sh`.

### F5: Machine-readable stdout

Pure data, no prefixes. `--json` = a single JSON object/array with an INTEGER `"version"`, built via `jq` (POSIX) or `ConvertTo-Json -Compress` (PS1) — never hand-concatenated. `--list-*` = one value per line, exit 0. Errors go to stderr as F1.

---

## Console color spec

Palette: bold/red/yellow/magenta/green/cyan/blue/dim, underline (`4m` / `$PSStyle.Underline`), and combined underline-cyan (`4;36m`, used for URLs). Sixteen named colors only — parity with `$PSStyle.Foreground`'s 16 names; no bright or 256-color variants. POSIX vars: `_nuc_c{1,2}_blue`, `_nuc_c{1,2}_underline`, `_nuc_c{1,2}_ulcyan` in `src/scripts/lib/lib.sh`.

### Semantic inline coloring

Message helpers tokenize message text before emitting. URL spans (`https?://[^ ]*`) render underline-cyan; single-quoted spans (`'[^']*'`) render blue. The quote pass runs first so a URL inside quotes still reads as a URL.

- Color-on only: when the stream color is off, output is byte-identical plain.
- Zero markup delimiters in the regex language — backtick-delimited markup is banned. Regex-only.
- Applied by `say`/`notice`/`error`/`warn`/`dry_run` (POSIX `_nuc_semantic_color` in `src/scripts/lib/lib.sh`) and `Write-NucleusInfo`/`Write-NucleusNotice`/`Write-NucleusError`/`Write-NucleusWarning`/`Write-NucleusDryRun`/`Write-NucleusDone` (PS1 `ConvertTo-NucleusSemanticColor` in `Format-NucleusOutput.psm1`).

POSIX detection (`_nuc_color_init` in `src/scripts/lib/lib.sh`):

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

---

## Log storage and rotation

Roots per host from `src/modules/services.json` `$logging`: MacBook `~/nucleus/logs` + `/Users/Shared/nucleus/logs` (SIP); NixOS `~/.local/state/nucleus/log` + `/var/log/nucleus`; Windows `%LOCALAPPDATA%\nucleus\logs` + `%ProgramData%\nucleus\logs`; overrides `NUCLEUS_LOG_DIR`/`NUCLEUS_SYSTEM_LOG_DIR`.

Files hold F1 timestamped lines plain. Unit output paths are hardcoded per-module (launchd `StandardOutPath`/`StandardErrorPath`, `/dev/null` for silent daemons); NixOS journald. `logging.capture` configures display/rotation/health-check behavior, NOT unit output paths.

Rotation: `log-gc-user.sh`/`log-gc-system.sh` copy-truncate + gzip; `NUCLEUS_GC_EXPIRY` default 7d; defaults from `src/modules/services.schema.json` `definitions.loggingEntry.properties` (maxSize 10000000, maxFiles 4, compress true, sanitize true); NixOS daily 12:00 timer.

---

## External exceptions

These output classes bypass the standard; new passthrough requires a spec entry with a one-line rationale — never silently added or removed.

- Third-party passthrough: nix/darwin-rebuild/home-manager build output, brew/cargo/bun/uv/rustup/ollama, git hook prek/commitlint/treefmt, winget configure, adb/qemu VM output.
- Probe suppression: vm.sh virsh/socat/ssh/adb/tart readiness, ai.sh ollama readiness, silent-daemon `/dev/null`.
- pwsh host rendering: `WARNING:` prefix and `Write-Error` rendering are host-injected.
- Vendored `vendor/` scripts untouched.
- Static doc content: MANUAL.md activation tail, `--- MANUAL SETUP (one-time, required) ---` banner in apply.ps1, `# ---- name ----` activation separators in macOS activation.nix.
- Pre-lib bootstrap lines: apply.sh root check (line 9).
- VM guest templates (POSIX + PS1): `vm-setup:` / `nucleus-vm:` labels — rendered templates; lib.sh / module unavailable in the guest.
- Android guest script: `virt_wifi:` — same rendered/guest context.
- Nix-inlined activation scripts: `lib/symlink-hardening.sh`, `lib/symlink-convergence.sh`, `services/cloud-drives-setup.sh` — literal context labels; lib.sh unreachable via `builtins.readFile` / activationScripts.
- Darwin activation scripts (MacBook host): plain by design — nix-darwin's generated `activate` runs under `#!/usr/bin/env -i`, wiping color env vars before any activation script runs; no policy-compliant propagation path.
- Shell-init contexts: `src/scripts/shell/init.zsh`, `src/scripts/shell/profile.ps1`, `src/platforms/macOS/scripts/macos-install-icloud-hooks.zsh` — F1 literal grammar; no helpers.
- Framework-local PS1: `src/scripts/lib/nix-test-eval.ps1` — `test: error:` literals already F1 grammar; no module import.
- Daemon log-file writers: `service-watchdog.sh` / `service-watchdog.ps1` — `[<ts>] watchdog: ...` F1-shaped lines written to log files.
- Test-harness summary markers: `FAIL:`, `PASS:`, `Testing:`, `ERROR:` in test result files.
- `tests/fixtures/logging-format` scope exclusion — fixture files intentionally exempt.
- Status/diff/event-log displays: `scripts/ai.ps1` Endpoints status table, `src/scripts/completions/gen-completions.ps1` diff output, `scripts/svc.ps1` event log, `step-runner.ps1:196` ERROR passthrough — verbatim status/diff lines, not F1 messages.
- Third-party additions (documented, not silenced): `sops updatekeys`, `rclone sync` stats, `tart`/`virsh`/`utmctl` console, `packer`/`nixos-generators`, `duperemove`, `journalctl` svc logs, `nix flake update`.

---

## Enforcement

Check step 14 (`src/scripts/checks/check-steps/14-repository-policy.{sh,ps1}` + `repository-policy.awk` logging-format mode) bans raw ANSI/`tput`/`echo -e`/`[char]27`/backtick-e/legacy `==== NN` markers outside a 9-file allowlist: lib.sh, step-runner.sh, step-runner.ps1, test-lib.sh, test-lib.ps1, Format-NucleusOutput.psm1, Format-NucleusOutput.Tests.ps1, Invoke-LogManagement.ps1, log-management.Tests.ps1; plus self-checks for NO_COLOR presence in lib.sh and Format-NucleusOutput.psm1.
