---
description: "Use when adding or editing files under scripts/, src/scripts/, or src/platforms/Windows/modules/. Covers script placement, newline policy, cross-platform behavior, runtime detection, and permission expectations."
name: "Scripts and Permissions"
applyTo: "scripts/**, src/scripts/**, src/scripts/lib/**, src/**/*.ps1, src/platforms/Windows/modules/scripts/**, src/modules/**/*.nix, src/hosts/**/*.nix"
---

# Scripts and Executable Permissions

## Scope

- Keep repo-level helper scripts in `scripts/`. Contents include paired `.sh`/`.ps1` entry points for bootstrap, check, cloud setup, gc, apply health-check, cloud sync, cloud reset, update, vm-setup, ai-sync, and other automation tasks.
- `scripts/` is the home of user-facing CLIs (the `nucleus-*` command set) ONLY. Every script in `scripts/` MUST be a registered `nucleusApp` (wired in `src/flake.nix` via `writeNucleusShellApplication`/`writeNucleusPowerShellApplication`). Convergence/activation tooling that is invoked only by activation scripts and is NOT a `nucleus-*` app does NOT belong in `scripts/` — it belongs under `src/scripts/` (e.g. `src/scripts/autostart.sh` + `src/scripts/autostart.ps1`, which are driven by `apps.json` and called from `macos-configure-app-autostart.sh` / `nixos-configure-app-autostart.sh` / `Sync-AppAutostart.ps1`).
- `src/scripts/` is the home of internal dev/CI tooling that is NOT a `nucleus-*` app (e.g. the completion generators live at `src/scripts/completions/`).
- Do not scatter contributor-facing or CI-facing automation across random folders when `scripts/` is the intended home.

## Cross-platform coordination

- Treat `scripts/bootstrap.sh` and `scripts/bootstrap.ps1` as paired entry points for the same bootstrap intent; keep capability parity as close as platform constraints allow.
- When adding a bootstrap dependency or behavior on one platform, update the other platform in the same change.
- Keep shared version pins in `scripts/bootstrap-versions.env` as the canonical location whenever both scripts depend on the same tool versions.

## Placement and naming

- Name scripts for the task they perform (`bootstrap`, `check`, `release`, etc.) and keep each script focused.
- Choose the extension that matches the intended shell or runtime.
- If a script becomes application code rather than repo automation, move it into the appropriate source tree.
- Detect a script's runtime from its extension, shebang, adjacent config files, and the commands it invokes.
- `src/scripts/apply.sh` (the Nix apply dispatcher) lives under `src/` because it is embedded in the flake as `apps.apply`; it follows the same doc and line-ending rules as `scripts/` shell scripts.
- **Host-specific placement rule**: scripts under `src/hosts/<Host>/scripts/` implement a host-specific feature; scripts under `src/platforms/<Platform>/scripts/` implement platform-shared behavior for that OS family. Cross-platform features belong in non-host subdirectories (`services/`, `configs/`, `packages/`, `editors/`, `secrets/`, `shell/`, `agents/`, `lib/`, `integrations/`). See [cross-host-feature-parity.instructions.md](cross-host-feature-parity.instructions.md) for the script deduplication policy.

## Per-directory naming patterns

Non-host subdirectories follow a two-track convention:

- **Verb-first** (most subdirs): `<verb>-<target>.<ext>` — the first word tells what action the script performs.
- **Entity-first** (`services/` only): `<entity>-<role>.<ext>` — the first word tells which component is managed.
- **Library scripts** (`lib/`): `<domain>.sh` — descriptive, no action verb. `lib.sh` is the universal library; other `.sh` files are domain-specific libraries.

| Subdirectory | Pattern | First-word role |
| ----------------------- | -------------------------------: | ---------------- |
| `root/` (in `scripts/`) | `<verb>-<target>.sh` | What action? |
| `agents/` | `<verb>-<target>.sh` | What action? |
| `completions/` | `<verb>-<target>.sh` | What action? |
| `configs/` | `<verb>-<target>.sh` | What action? |
| `editors/` | `<verb>-<target>.sh` | What action? |
| `integrations/` | `<verb>-<target>.sh` | What action? |
| `lib/` | `<domain>.sh` | What domain? |
| `packages/` | `<verb>-<target>.sh` | What action? |
| `secrets/` | `<verb>-<target>.sh` | What action? |
| `services/` | `<entity>-<role>.sh` | Which component? |
| `shell/` | `init.*` or `<verb>-<target>.sh` | Varies |
| `src/hosts/<Host>/scripts/` | `<prefix>-<verb>-<target>.<ext>` | What action? |
| `src/platforms/<Platform>/scripts/` | `<prefix>-<verb>-<target>.<ext>` | What action? |

`<prefix>` is `macos-` for MacBook, `nixos-` for NixOS, etc.

## Argument convention for extracted scripts

- **All extracted inline scripts must accept inputs via positional arguments, not environment variables.** This keeps reasoning local and makes each script testable in isolation.
- `src/scripts/services/caddy-trust.sh` historically uses `NUCLEUS_REPO_ROOT` (an environment variable) for backward compatibility. New scripts must use positional arguments instead.
- **Helper scripts in `src/scripts/` (e.g. `register-host-age-key.sh`, `install-prek-hooks.sh`) use `--repo-root <path>` flags, not bare positional args.** Call sites in `src/scripts/apply.sh` must use the flag form. This prevents recurring bugs where a bare path is passed to a script that expects `--repo-root`.
- **Store-path args for external commands.** Activation scripts that invoke external tools (e.g. `jq`, `sops`, `age`) receive them as Nix store-path arguments (e.g. `_jq_bin="$1"`) and MUST invoke them via the variable (e.g. `"$_jq_bin"`), never as bare command names. This prevents "command not found" failures in minimal PATH environments. Check step 16 enforces that every `_X_bin` positional-arg declaration has at least one command-like usage.
- **Activation tool resolution (step 17).** The `activation-tool-resolution` check (step 17) scans activation scripts under `src/scripts/` for bare external command invocations that are NOT resolved via a store-path arg variable or an explicit `PATH=` prepend. The only sanctioned `PATH` use is a deliberate `PATH=` prepend where a tool must be visible to itself or child processes (e.g. bun, rustup, cargo). ShellCheck cannot verify command availability at activation time, so this custom check is the guard. If a legitimate bare command is flagged, fix it by passing the tool as a store-path arg (preferred) or add a `# check-suppress:activation-tool:` annotation with a reason.

## Relative pathing convention

All scripts that source other files (libraries, configs, etc.) MUST derive their
directory via SCRIPT_DIR and source via SCRIPT_DIR-relative paths. This
makes scripts work from any cwd, prevents `CDPATH` interference, and resolves
symlinks to physical paths (matching nix store resolution).

Standard form:

```sh
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/relative/path"
```

- Use `pwd -P` to resolve symlinks to physical paths.
- Use `CDPATH=''` to prevent the `CDPATH` environment variable from
  interfering with `cd`.
- Never use bare `$(dirname "$0")` in a source line; always pair with a
  SCRIPT_DIR assignment at the top of the script.
- For scripts in `scripts/` that resolve via `$_self` (symlink-safe), use
  `dirname -- "$_self"` instead of `dirname -- "$0"`.

## PowerShell file naming

When adding or renaming standalone PowerShell entry points, use PascalCase and an approved `Verb-Noun` form (e.g. `Get-SystemInventory.ps1`).

The `scripts/` directory is the exception: helper scripts there keep the paired shell basename so `.sh` and `.ps1` stay aligned. That means `bootstrap.sh` pairs with `bootstrap.ps1`, `check-sh.sh` pairs with `check-sh.ps1`, and `check-pwsh.ps1` is a separate entry point for PowerShell linting (PSScriptAnalyzer) — not the Windows twin of `check-sh.sh`.

For reusable Windows modules under `src/platforms/Windows/modules/`, align the filename with the exported function name and prefer a single exported `Verb-Noun` function per file. If a module is renamed, update the dot-sourcing paths in `src/hosts/Windows/apply.ps1` in the same change. Collection-operating functions must use collection-indicating singular nouns — see [pwsh-lint-policy.instructions.md](pwsh-lint-policy.instructions.md) (`PSUseSingularNouns`, anti–naive-de-pluralization).

If a PowerShell file exports multiple functions or none, keep it in `src/platforms/Windows/modules/` as a utility module and name the file for its shared purpose.

### PowerShell here-string extraction

The no-embedding invariant, shared cross-platform content rule, token convention, and exceptions are canonical in [embedded-content.instructions.md](embedded-content.instructions.md). The mechanical details:

When extracting inline PowerShell here-strings from `src/platforms/Windows/modules/` into standalone scripts:

- Extract the script body to `src/platforms/Windows/modules/scripts/<name>.ps1`.
- In the caller, read it with: `Get-Content -Raw (Join-Path -Path $PSScriptRoot -ChildPath "..\scripts\<name>.ps1")`
- From any module subdirectory (`user/`, `system/`, `editors/`), `..\scripts\` resolves to `modules/scripts/`.
- For double-quote here-strings (`@"..."@`) with expanded variables, use token replacement: `$content = (Get-Content -Raw ...) -replace '__TOKEN__', $value`.
- Single-quote here-strings (`@'...'@`) can be read directly with no replacement needed.

## CLI option and variable naming

Use `--XXX`/`--no-XXX` flag pairs for CLI options and positive variable names for scripts and config knobs. Every feature supports both `--XXX` and `--no-XXX` regardless of default state.

| Aspect | Convention |
| ----------------- | --------------------------------------------------------- |
| Shell variable | `ai_sync=true` (positive, no prefix) |
| Conditional check | `if [ "$ai_sync" = false ]` or `if [ "$ai_sync" = true ]` |
| POSIX CLI flag | `--ai-sync` (enables) / `--no-ai-sync` (disables) |
| PowerShell param | `[switch]$AISync` + `[switch]$NoAISync` |
| PowerShell call | `-AISync` (enables) / `-NoAISync` (disables) |

Rules:

1. Every feature with a boolean CLI flag MUST support both `--XXX` and `--no-XXX` (or PowerShell equivalent: `-XXX` and `-NoXXX`).
2. Shell variables MUST use bare positive names without prefixes: `ai_sync`, `replica_sync`, `vm_setup`, `secret_health` — not `do_ai_sync`, `with_replica_sync`, etc.
3. PowerShell internal variables MUST use `$noXXX` (lowercase) for the local copy and `$NoXXX` (PascalCase) for the param variable.
4. Do not prefix with `do_`, `with_`, or any other semantic qualifier. The variable name itself is the boolean.

## Line endings and permissions

- Respect `.editorconfig` and `.gitattributes` for line endings. New script extensions need explicit policy before widespread adoption.
- Every `.sh`, `.ps1`, and `.bat` script file anywhere in the repository must have its executable bit tracked in Git, regardless of location. This applies to Windows scripts too — Git stores the executable bit independent of CRLF line endings, and many CI environments check the mode before invoking scripts. Set it with `git update-index --chmod=+x <path>` when adding or renaming any script. Verify the stored mode with `git ls-files --stage <path>` (mode `100755` is correct; `100644` is not). Non-script data files such as `bootstrap-versions.env`, `.yml`, `.json`, and `.nix` files must remain `100644`.
- If you add a new script extension or change placement conventions, update the related config and any tests in the same change.

## Sorting

- Sort `case` branch labels, environment variable blocks, and any other unordered list-like constructs alphabetically.
- Do not sort `case` branches whose matching order is semantically significant (e.g. a catch-all `*` branch must remain last).

## Portability and safety

- Keep scripts non-interactive by default unless that is their purpose.
- Prefer explicit error handling, predictable exit codes, and idempotent operations.
- Do not assume Bash-only features in `.sh` unless you require Bash and document that requirement.
- Prefer full cmdlet names over aliases in committed PowerShell scripts.

## Privilege-gating policy

Any code that checks whether it holds a privilege (sudo/root on POSIX;
Administrator/elevated on Windows) follows this rule. A privilege is "required"
only when the operation cannot succeed without it; a script that never
needs the privilege is unaffected.

1. **Default (all `src/` code, and any non-user-facing path):** if the privilege
   is required but unavailable, **hard-error** (exit non-zero with a clear
   message). No warn-and-continue on a privilege gap. Continuing the operation
   *without* the privilege is also forbidden — attempting to proceed (e.g.
   falling back to a degraded non-privileged path) is not allowed. Such
   continue-without-privilege branches add parallel code paths that must be
   maintained for no benefit, since the operation cannot succeed correctly
   without the privilege. Hard-error is the only acceptable outcome.
2. **User-facing exception (`scripts/` only — the `nucleus-*` CLI set, NOT
   `src/scripts/`, `src/platforms/*/scripts/`, `src/hosts/*/`):** when an
   operation *requires* a privilege that the current process lacks, the script
   **escalates** to obtain it (POSIX: `sudo` re-exec / prefix; Windows: `RunAs`
   self-elevation). Only **warn-and-skip if escalation is genuinely impossible**
   (no `sudo` binary, UAC cancelled). If already privileged, proceed directly.
   This rule is scoped to *privilege-requiring operations only* — a user-facing
   script that never needs the privilege is unaffected and must not be forced to
   escalate. This rule replaces prior warn-and-skip behavior for cases where the script already gates on a missing item (e.g. `svc` system-domain).
3. **Inverse family — hard-refuse when already elevated (NOT warn-and-skip):**
   scripts that *refuse to run already-elevated* because they manage escalation internally (`scripts/bootstrap.sh`, `scripts/bootstrap.ps1`, `src/scripts/apply.sh`, `src/hosts/Windows/apply.ps1`). The outcome is a **hard refusal** (non-zero exit), not a warning.
   - **Windows admin-normal provisioning (no non-admin fallback):** writing to `%ProgramData%\nucleus\bin` (agent-host-shell setup, scheduled-task registration) runs under `RunAs` self-elevation, like POSIX `sudo`. No non-admin fallback path. Do not assume a non-admin case for Windows provisioning.
4. **Non-escalatable privileges (documented exceptions, keep warn-and-skip):**
   - macOS Full Disk Access (TCC privacy grant — cannot be obtained via sudo).
   - `nucleus-apply health-check` diagnostic reporting (its purpose is to surface gaps, not act).
   - `Invoke-VMSetup.ps1` WHPX detection (informational capability probe, not a gate).
5. **Applies to all platforms** (macOS, NixOS, Windows).

Canonical escalation mechanisms to standardize on (already exist):

- POSIX sudo keepalive + re-exec: `src/scripts/apply.sh` `start_sudo_keepalive`
  (lines ~186-211) and `run_nix_as_root`; `scripts/gc.sh` `sudo env … log-gc-system.sh`
  (lines ~688-697).
- Windows self-elevation: `src/hosts/Windows/apply.ps1` `RunAs` + `-Elevated`/`-ParamsJson`
  (lines ~337-369).
- Windows scheduled-task escalation: `scripts/gc.ps1` `Start-ScheduledTask 'log-gc-system'`
  (lines ~508-516); task registered in `src/hosts/Windows/system/scheduler.dsc.yml`,
  `src/modules/posix-base.nix`, `src/hosts/NixOS/activation.nix`.

**Separate concern — Jellyfin admin token:** the Jellyfin app-level admin token
(`.Policy.IsAdministrator`) is NOT covered by this policy and is NOT a
warn-and-skip exception. A missing admin token normally means the user has not
yet configured an admin Jellyfin account for themselves; if they lack admin they
must not configure library items at all. Such code must **hard-error** (exit
non-zero / `throw`), not warn-and-skip. This is a configuration-prerequisite
check, not an escalation case.

## Explicit Parameter Passing (PowerShell)

**All PowerShell functions must enforce caller awareness through explicit parameters.**

- **Mandatory behavioral parameters**: parameters controlling state changes (`Enabled`, `Users`, `Activated`, etc.) must be `[Parameter(Mandatory)]`. Do not default to `$true` or assume the current user.
- **No path auto-derivation**: never auto-derive `RepoRoot`, `ModuleDir`, `ConfigDir`, or other paths from `$PSScriptRoot`. Callers must pass them explicitly so they are aware of which paths will be modified.
- **Explicit user context always**: functions touching user profiles or home directories must have explicit `-Username` or `-Users` parameters. Never silently default to the current user or auto-discover users from the filesystem.
- **Remove dead paths**: this repository does not carry deprecated parameters, conditional migration paths, or old configuration formats. Remove the old path entirely and document the breaking change in examples and commit messages. Git preserves all history; archived code need not live alongside current implementation. See [AGENTS.md#no-backwards-compatibility](../../../AGENTS.md#no-backwards-compatibility) — no in-code migration cleanup; execute one-off host cleanup before merge, never persist migration steps in the repo.
- **Complete function signatures**: every function signature must show all mandatory parameters in its `.SYNOPSIS` and `.EXAMPLE` sections so callers know what they are required to pass.

## Terminology in Examples

**Use canonical usernames in all code examples and documentation:**

- **`admin`**: represents the primary/elevated user in examples. Use this for any context where the primary user is required or most common (e.g. `-PrimaryUsername 'admin'`, `-Users @('admin')`).
- **`guest`**: represents any secondary or unprivileged user. Use when examples need to show multi-user scenarios (e.g. `-Users @('admin', 'guest')`).

This standardization makes examples portable and immediately clear about user context without needing explanation or configuration.

## Tooling alignment

- Keep script behavior consistent with CI, `AGENTS.md`, and prompt guidance.
- If a script wraps project tooling, keep the underlying canonical commands discoverable in docs and config instead of hiding the real workflow.
- When script location or behavior changes, re-check `.github/workflows/ci.yml`, `.vscode/settings.json`, and any prompt or instruction files that reference it.

## apply.sh health-check subcommand SOPS identity resolution

`scripts/apply.sh` (the `health-check` subcommand) must export `SOPS_AGE_KEY_FILE` pointing to `/etc/sops/age/machine.txt` (the machine age key written by `deriveHostAgeKey`) before its `sops -d` probe loop, since `sops` does not search that path by default. Without this, `sops` falls through to GPG, which may not have the secret key in the keyring at health-check time.

See the `check_secret_health()` function in `scripts/apply.sh` (the `health-check` subcommand) for the implementation.

## CWD independence — all `nucleus-*` commands must work from any working directory

Repository root resolution goes through `derive_repo_root()` in `src/scripts/lib/lib.sh` (priority order: `NUCLEUS_REPO_ROOT` environment variable → `<SYSTEM root>/repo-root` system file (macOS `/Library/Application Support/nucleus/repo-root`, NixOS `/var/lib/nucleus/repo-root`; POSIX all-process parity with Windows Machine scope) → `SCRIPT_DIR` offset walk checking `src/flake.nix`, then `.nucleus-repo-root` marker in the store tree → `git rev-parse` fallback).

`writeNucleusShellApplication` in `src/flake.nix` bakes `.nucleus-repo-root` into each nucleus app store tree at build time from eval-time `NUCLEUS_REPO_ROOT` (forwarded by `apply.sh` through `run_nix_as_root`). `src/modules/repo-root-file.nix` materializes `/etc/nucleus/repo-root` on macOS and NixOS during apply. `posix-security.nix` adds `Defaults env_keep += "NUCLEUS_REPO_ROOT"` so `sudo` preserves the variable when the invoking shell already has it.

Scripts must not assume the current working directory is inside the repository. Use `derive_repo_root()` or the `NUCLEUS_REPO_ROOT` environment variable for any path that resolves files relative to the repo root. Script-specific `--repo-root` flags (e.g. `replica-sync.sh`) are acceptable as additional manual overrides but must not be the sole mechanism for normal operation.

## PowerShell linting

`scripts/check-pwsh.ps1` splits work across the check and test pipelines because PSScriptAnalyzer is slow:

| Pipeline | Step | Flags | What runs |
| -------- | ---- | ----- | --------- |
| `check` (pre-commit) | 2 `powershell-lint` | `-SkipStep PSSA` | Parser syntax validation only |
| `test` (pre-push) | 2 `powershell-lint-test` | `-SkipStep Syntax -Settings test-PSScriptAnalyzerSettings.psd1` | PSScriptAnalyzer only (full rule set) |

Standalone `nucleus-check pwsh` runs both phases (no `-SkipStep`). Settings files: `scripts/check-PSScriptAnalyzerSettings.psd1` (when PSSA runs outside the test pipeline) and `scripts/test-PSScriptAnalyzerSettings.psd1` (test step 2). Do not configure rule exclusions in the checker script itself.

Always exclude `PSUseBOMForUnicodeEncodedFile` in settings files — UTF-8 without BOM is the repository standard (`.editorconfig`).

Verb-Noun and collection-singular naming policy: [pwsh-lint-policy.instructions.md](pwsh-lint-policy.instructions.md).

## Runtime configuration (`nucleus-config`)

Runtime toggles live at `~/.local/state/nucleus/config.json` (outside `~/.config/` so changes survive rebuilds). All toggles default to `true` when the file or key is absent, enforced by the implementation in `scripts/config.sh` / `scripts/config.ps1`.

Services read the config file directly (not via `nucleus-config`) for early-boot compatibility, following the same pattern on both POSIX and Windows.

When adding a toggle: add a default entry to the `DEFAULTS`/`$Defaults` map in both script implementations, then update consuming code to read the key (defaulting to `true`).

## Centralized daemon/service refresh

All program/daemon/service killing, refresh, and restart operations must go through centralized library functions:

- **macOS**: `src/scripts/lib/macos-launch-services.sh` (`refresh_*` functions)
- **Windows**: `src/platforms/Windows/modules/Set-NucleusService.ps1`

Do not inline killall/Stop-Service commands in activation blocks or individual scripts. This centralizes control per OS and prevents redundant kills in the same activation run.

For macOS activation blocks that need daemon refresh, use wrapper scripts under `src/platforms/macOS/scripts/` (or `src/scripts/lib/macos-launch-services.sh` directly when inlined) that source the library and call the appropriate `refresh_*` function. Invoke via the activation bundle subprocess pattern.

## When a script needs its own file

A script under `src/scripts/` earns its own file when it falls into one of these categories. Otherwise, inline directly in the Nix activation block.

**Separate file when:**

1. **Substantial logic** — loops, conditionals, data processing, error handling, or multi-step algorithms that would bloat the Nix activation string.
2. **Exec dispatch** — script validates prerequisites then `exec`s another command (e.g., `gc-sweep.sh`). The validation+dispatch pattern keeps activation blocks focused.
3. **Thin dispatcher** — script calls another tool/script with argument setup (e.g., `merge-obsidian-json.sh`). The argument preparation and error handling justify separation.
4. **Persistent daemon/service** — long-running process with lifecycle management.

**Inline when:**

1. **Thin library wrapper** — script only sources a library (from `src/scripts/lib/`) and calls functions from it, with no additional logic. No loops over data, no conditionals on runtime state, no data transformation. Embed the library via `${builtins.readFile <lib-path>}` in the activation block and call the functions directly. Wrappers that iterate over data entries (loops) still justify a separate file.
2. **Trivial one-command** — script whose entire logic is a single command or a few simple commands with minimal/no control flow (no loops, no conditionals on runtime state, no data transformation).

See `nix-authoring.instructions.md` ("Inline code extraction boundaries") for the complementary Nix-side policy on what stays inline.

## Simplification patterns

Apply these patterns when maintaining scripts under `src/scripts/`:

- **Tiny libs (<20 lines, single caller)**: When a lib file provides only 1-2 variable definitions or one small function used by a single caller, inline the content directly into the caller and delete the lib file.
- **Trivial scripts (<10 lines, simple if/command check)**: Inline into the parent Nix activation string via `${builtins.readFile ...}` instead of maintaining a separate file.
- **Console user boilerplate (MacBook scripts)**: When multiple scripts independently probe `/dev/console` for UID/username, extract into a shared function under `src/scripts/lib/macos-console-user.sh`.
- **Service script helper duplication**: When two daemon scripts define identical small functions (e.g., `require_command`), extract to `src/scripts/lib/require-command.sh` and prepend at Nix build time.
- **Shared symlink convergence logic**: When scripts share structural overlap (iterate find results → remove stale → create missing), extract into `src/scripts/lib/symlink-convergence.sh`.
- **Nix prepend pattern**: For scripts built via `pkgs.writeShellScript` or activation strings, prepend lib content at build time: `(builtins.readFile ../scripts/lib/foo.sh) + (builtins.readFile ../scripts/main-script.sh)` — removes the runtime sourcing path dependency.

## Library purity

Library files (under `src/scripts/lib/`) are pure function/constant definitions. The same rules apply by analogy to Windows PowerShell helper modules under `src/platforms/Windows/modules/scripts/`.

1. **No top-level side effects on import.** A lib file defines functions and variables only — never execute commands at import time. No `set -eu` at the top level (only inside function bodies). No auto-invocation at end of file.

2. **No Nix placeholders.** Lib files must never contain `__TOKEN__`-style placeholders for Nix `builtins.replaceStrings`. All data enters via function parameters.

3. **Nix must not `builtins.readFile` lib files.** Nix modules source lib files at runtime (`. "$REPO_ROOT/src/scripts/lib/..."`) rather than inlining them at build time.

4. **Data from Nix goes to the consumer script first, then to lib via function args.** The consumer (activation script, service script, or standalone Nix-derived script) receives data from Nix through its own parameters or token substitution, then passes it to lib functions as arguments.

### Exception

A lib file may be embedded via `builtins.readFile` when it contains a clean function definition (no tokens, no env var dependencies) and is wrapped into a standalone script (e.g., a launchd daemon script) that executes independently. The embedded lib must remain pure — all external inputs arrive as function arguments from the wrapping code.
