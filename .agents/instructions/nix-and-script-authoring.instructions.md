---
description: "Use when authoring or editing Nix files in src/, scripts under scripts/ or src/scripts/, or PowerShell modules under src/platforms/Windows/modules/. Covers flake structure, module conventions, script placement, activation blocks, writeNucleusShellApplication, and cross-platform script patterns."
name: "Nix and Script Authoring"
applyTo: "src/**/*.nix, src/**/*.ps1, scripts/**, src/scripts/**, src/platforms/Windows/modules/**, src/modules/**/*.nix, src/hosts/**/*.nix"
---

# Nix and Script Authoring

See `AGENTS.md` Repository Shape for the canonical repo layout. Subagent path note: when a subagent extracts or references a file from a Nix module, the path must be relative to the Nix file's directory, not the repo root. For `src/modules/*.nix`: `../scripts/...`. For `src/platforms/<Platform>/modules/*.nix`: `../../../scripts/...` (cross-platform) or `../../scripts/...` (platform). For `src/hosts/<Host>/*.nix`: `../../scripts/...`.

## Scope

- Keep repo-level helper scripts in `scripts/`. Contents include paired `.sh`/`.ps1` entry points for bootstrap, check, cloud setup, gc, apply health-check, cloud sync, cloud reset, update, vm-setup, ai-sync, and other automation tasks.
- `scripts/` is the home of user-facing CLIs (the `nucleus-*` command set) ONLY. Every script in `scripts/` MUST be a registered `nucleusApp` (wired in `src/flake.nix` via `writeNucleusShellApplication`/`writeNucleusPowerShellApplication`). Convergence/activation tooling that is invoked only by activation scripts and is NOT a `nucleus-*` app does NOT belong in `scripts/` — it belongs under `src/scripts/`.
- `src/scripts/` is the home of internal dev/CI tooling that is NOT a `nucleus-*` app (e.g. the completion generators live at `src/scripts/completions/`).

## Placement and naming

- Name scripts for the task they perform (`bootstrap`, `check`, `release`, etc.) and keep each script focused.
- Choose the extension that matches the intended shell or runtime.
- If a script becomes application code rather than repo automation, move it into the appropriate source tree.
- Detect a script's runtime from its extension, shebang, adjacent config files, and the commands it invokes.
- `src/scripts/apply.sh` (the Nix apply dispatcher) lives under `src/` because it is embedded in the flake as `apps.apply`; it follows the same doc and line-ending rules as `scripts/` shell scripts.
- **Host-specific placement rule**: scripts under `src/hosts/<Host>/scripts/` implement a host-specific feature; scripts under `src/platforms/<Platform>/scripts/` implement platform-shared behavior for that OS family. Cross-platform features belong in non-host subdirectories (`services/`, `configs/`, `packages/`, `editors/`, `secrets/`, `shell/`, `agents/`, `lib/`, `integrations/`). See `cross-host-feature-parity.instructions.md` for the script deduplication policy.

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

## Cross-platform coordination

- Treat `scripts/bootstrap.sh` and `scripts/bootstrap.ps1` as paired entry points for the same bootstrap intent; keep capability parity as close as platform constraints allow.
- When adding a bootstrap dependency or behavior on one platform, update the other platform in the same change.
- Keep shared version pins in `scripts/bootstrap-versions.env` as the canonical location whenever both scripts depend on the same tool versions.

## Flake conventions

- All flake inputs must follow `nixpkgs` via `inputs.nixpkgs.follows = "nixpkgs"` to avoid duplicate Nixpkgs evaluations.
- Keep `username` and system strings in the `let` block at the top of `flake.nix`; do not scatter literal strings through the output attrset.
- Use `config.allowUnfree = true` only inside `mkPkgs`; do not set it globally at the module level unless a specific host requires it.
- After adding or changing any input, regenerate `src/flake.lock` with `nix flake lock` run from inside `src/`.

## Host conventions

- Every host module must import `../../modules/core.nix` so the shared package set is consistently applied.
- Both POSIX hosts must import `posix-base.nix`, `posix-security.nix`, `posix-sops.nix`, `posix-user-shell.nix`, and `gnupg.nix` — these provide the shared system-layer options.
- System-specific options (drivers, hardware modules, kernel args) belong in the host file, not in shared modules.
- Shared modules must not hardcode paths under `src/hosts/` (for example `../hosts/<host>/MANUAL.md`). If a shared module needs host-scoped data, declare a shared option in `src/modules/home.nix` (or another shared module) and set it from each host entrypoint.
- Set each host's `system.stateVersion` to its bootstrap-era value and never bump it automatically.
- NixOS hardware stubs (`availableKernelModules`, `videoDrivers`) should be replaced with the real `hardware-configuration.nix` generated by `nixos-generate-config` after first install.

## Module conventions

- Shared modules must guard NixOS-only options with `lib.mkIf` checks on `options ? environment` or equivalent; Home Manager modules must likewise guard `home.*` options.
- Do not use `with pkgs;` in module-level attribute sets — use explicit `pkgs.name` references or a local `let` binding to keep derivations traceable.
- Home Manager `home.file` entries should use `lib.optionalAttrs` with a `builtins.pathExists` guard so missing dotfile sources don't break evaluation.

### Explicit parameter passing requirements

**No implicit defaults, no auto-derived paths, no backwards compatibility code.**

All Nix modules must enforce explicit configuration and avoid implicit assumptions:

- **Explicit option defaults**: when defining `lib.mkOption`, provide meaningful default values only when the default is obvious (e.g. `false` for feature flags, `[ ]` for lists). For complex or context-dependent defaults, require the user to specify them; use `description` to explain the choice.
- **Documentation examples must use canonical usernames**: any `.example` field in module options or inline code examples must use `admin` for primary/elevated users and `guest` for secondary/unprivileged users. Paths should reference `/home/admin` or `/Users/admin` rather than real usernames from the repo history.

## Script builders: `writeNucleusShellApplication` over `writeShellApplication`

Always use `pkgs.writeNucleusShellApplication` instead of `pkgs.writeShellApplication` for creating shell scripts from Nix. `writeNucleusShellApplication` is the repo's custom wrapper available via the `pkgs` overlay.

`writeNucleusShellApplication` provides:

- `scriptName` — repo-root-relative path without `.sh` suffix. Paths under `scripts/` resolve via `scripts-bundle` (e.g. `"scripts/gc"` for user CLIs). All other paths resolve via `script-tree` (e.g. `"src/scripts/services/jellyfin-daemon"`, `"src/platforms/macOS/scripts/macos-purge-preferences"`, `"src/hosts/MacBook/scripts/macos-daemonize-linux-builder"`). The script receives `$@` from the wrapper; pass values as positional args at the call site. The entry script is always reachable at `$out/<scriptName>.sh` because every call site mirrors both trees into `$out`.
- `text` — inline the script body directly instead of referencing an external file. Does not bundle trees; sets up `PATH` from `runtimeInputs`, and appends the text content to the wrapper. Use when the script body is trivial or when a shared script cannot be reused due to host-specific values.
- `extraEnv` — injects Nix-computed values as environment variables into the wrapper script. Values are automatically shell-escaped. **Prefer positional args for standalone scripts** (see "CLI-arg-first pattern" below). Use `extraEnv` when the script body is a **shared body sourced by multiple callers** (see "Shared script body pattern" below) — the env var contract stays uniform across callers, preventing dual-parsing of `$1` and env-var fallbacks in the shared code.

`writeShellApplication` (from nixpkgs) does not support `bundleDefault`, `extraEnv`, or `text`. Scripts built with it cannot source sibling libraries via `SCRIPT_DIR`-relative paths, breaking when a script evolves to need library access.

The only exception is when technical constraints prevent using `writeNucleusShellApplication` (e.g., dynamic names in function context as in `cloud-drives.nix`). Add a `# WHY:` comment explaining the constraint.

### CLI-arg-first pattern (standalone scripts)

Prefer passing Nix-computed values as positional CLI arguments over environment variables. Applies to:

- **Launchd agents**: add extra elements to `ProgramArguments` array instead of `extraEnv`. The script receives them as `$1`, `$2`, etc. This keeps the agent invocation self-documenting and makes the script independently testable.
- **Activation hooks**: pass values as script arguments in the activation string (already standard practice; avoid `export` before script calls).
- **`home.file` wrappers**: when a binary from `writeNucleusShellApplication` is deployed as a CLI command (via `source`), and the caller cannot pass arguments, wrap it in a `text` entry that hardcodes the values:

  ```nix
  home.file."my-command" = {
    executable = true;
    text = ''
      exec '${pkg}/bin/nucleus-my-command' 'hardcoded-value' "$@"
    '';
  };
  ```

  This avoids `extraEnv` while keeping the shared script reusable for other callers.

### Shared script body pattern

When a `.sh` file under `src/scripts/` is both invoked directly via `scriptName` and `source`d by another script (e.g., a service script that calls functions and does extra work after the shared body), use `extraEnv` with `scriptName` to pass Nix-computed values. The shared body reads env vars set by both callers — `extraEnv` for the `scriptName` caller, POSIX shell defaults for the `source`-based caller — without parsing positional arguments.

```nix
extraEnv = {
  NIX_STORE_BIN = "${pkgs.nix}/bin/nix";
  MANAGED_PREF_DOMAINS = builtins.concatStringsSep " " resetUserPreferenceDomains;
};
scriptName = "src/platforms/macOS/scripts/macos-purge-preferences";
```

This prevents dual-parsing `$1` vs env-var fallbacks in the shared body, avoids a `text` wrapper that duplicates the `extraEnv` mechanism and bypasses PATH setup, and prevents breaking the `source`-based caller.

Do NOT use `text` to wrap a shared-body script with inline env var assignments — that duplicates `extraEnv`. If the script body exists as a file under `src/scripts/`, reference it via `scriptName` (with `extraEnv` for values). Reserve `text` for truly inline scripts or host-specific wrappers without a shared body.

Shellcheck for bundled scripts runs in `nucleus-check sh` / CI (`script-tree.nix` and per-app derivations do not shellcheck at build time). See `nix-store-space.instructions.md` for store-space policy.

### Env-var fallback pattern for scripts with callers that use positional args

Scripts that accept positional args should also support the corresponding env var as a fallback, enabling both launchd-agent usage (args from ProgramArguments) and direct invocation during development:

```bash
VAR="${ENV_VAR_NAME:-${1:-default_value}}"
```

This pattern is used by `open-host-manual.sh`, `macos-set-gui-env.sh`, and `configure-file-manager-optimize-pdf.sh`.

### Sites that cannot use the CLI-arg pattern

Some scripts embed Nix-computed values via `builtins.readFile` into activation blocks or `writeTextFile` derivations. These are **Category 3** sites where the content is either:

- A library function definition (not a script body) that must be sourced by multiple callers.
- A token-replaced template that uses `builtins.replaceStrings` (the established token-injection pattern).

These sites are not candidates for CLI-arg conversion. Examples: `macos-icloud-exclusions.sh` (sourced by both activation hook and launchd agent), `macos-fda-warning.sh` (library with no script entry point). Do not convert unless an alternative dispatch mechanism is introduced.

## Runtime imperative scripts vs. inline activation shell

Extract runtime imperative logic (SOPS decryption, API calls, service polling) into separate invocable scripts instead of inlining in Nix indented strings. Keeps activation files readable, allows independent testing, and avoids duplication across hosts.

See `src/scripts/services/jellyfin-sync.sh` for an example.

## Activation blocks

### No library sourcing in activation blocks

Libraries under `src/scripts/lib/` must never be sourced directly inside Nix activation blocks. The `REPO_ROOT="${repoRoot}"` + `. "$REPO_ROOT/src/scripts/..."` pattern couples activation timing to library file-system layout and makes activation scripts opaque to shell analysis tools.

Instead, create a small import wrapper script under `src/scripts/lib/` that sources the library (using `SCRIPT_DIR`-based path resolution). Activation blocks use `builtins.readFile` of the import wrapper only.

The only exception is standalone scripts under `src/scripts/` that are not libraries (e.g. scripts executed for their side effects, like `src/platforms/macOS/scripts/macos-configure-preflight-privacy.sh`). These may be run directly via `builtins.readFile` without an import wrapper.

A second exception covers **thin library wrappers** (scripts that only source a library and call functions, with no loops or conditionals): embed the library via `${builtins.readFile <lib-path>}` in the activation block and call the functions inline. This is already practiced in `src/platforms/macOS/modules/default.nix`, `home.nix`, and `config-utils.nix` (see "When a script needs its own file" for the full policy).

### Activation script value injection

When injecting Nix-evaluated values (store paths, JSON, repo root) into activation scripts embedded via `builtins.readFile`, use `builtins.replaceStrings` to substitute `__UPPERCASE_WITH_DOUBLE_UNDERSCORES__` tokens in the script source. Do NOT use shell-level variable exports (`PATH=...; export PATH`, `VAR="..."; export VAR`) before the script invocation — this is fragile, bypasses PATH isolation, and mixes compile-time and runtime concerns.

The script file declares token placeholders as variable values only (not variable names, since `builtins.replaceStrings` replaces all occurrences including names). A distinct prefix on the token value enables fallback detection via `case`:

```bash
VAR='__NUCLEUS_UNIQUE_TOKEN__'
case "$VAR" in __NUCLEUS_*)
  VAR='default_value'
  ;;
esac
```

Then in the Nix activation block, replace each token with its Nix-evaluated value:

```nix
builtins.replaceStrings
  [ "__NUCLEUS_UNIQUE_TOKEN__" ]
  [ repoRoot ]
  (builtins.readFile ./script.sh)
```

For tool paths, prefer prepending a token-replaced bin directory to `PATH` inside the script (after fallback detection), which resolves all bare commands without touching every invocation:

```bash
_path_prepend='__NUCLEUS_PATH_PREPEND__'
case "$_path_prepend" in __NUCLEUS_*)
  _path_prepend=''
  ;;
esac
if [ -n "$_path_prepend" ]; then
  export PATH="$_path_prepend:$PATH"
fi
```

See `src/scripts/services/jellyfin-sync.sh` and its POSIX orchestration caller (`src/scripts/apply.sh`; Windows: `src/hosts/Windows/apply.ps1` via `Sync-Jellyfin*`) for the canonical implementation.

**Comments must never contain token placeholder strings.** Since `builtins.replaceStrings` replaces all occurrences, any token string (e.g. `__NUCLEUS_REPO_ROOT__`) appearing in a comment will also be substituted, leaving meaningless text.

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

## Inline code extraction boundaries

Some inline shell code in Nix files is intentionally kept inlined — extracting it would add complexity without benefit. These patterns are NOT extractable:

### 1. Per-entry Nix-generated loops

Code generated by `lib.concatMapStrings` or `lib.concatStringsSep` over Nix data (SOPS files, cloud mount configs, user lists, wallpaper entries) stays inline because the **loop structure IS the Nix expression**. Each iteration produces different code based on entry properties.

Examples: `verify-secret-decryption` (secrets.nix, ~230 lines over SOPS entries), per-mount/replica setup (cloud-drives.nix), per-bundle lsregister commands (app-bundles.nix), per-symlink-target commands (config-utils.nix), per-user picard overrides (home.nix).

### 2. Trivially small (<10 lines) with Nix references

Code too small to justify a file — the Nix expression is the entire body. Example: `configureXcodeSelect` (MacBook/activation.nix, ~5 lines referencing `pkgs.apple-sdk`).

### 3. Split-pattern items (helper extracted, Nix wrapper remains)

Pure-shell logic was extracted to `src/scripts/`, but the Nix-evaluated wrapper (env var interpolation, generated predicates, Nix function calls) stays inline. This is the expected split pattern.

Examples with their extracted helpers:

- `devSpotlightExclusions` → `dev-spotlight-exclusions.sh` (find predicate stays in Nix)
- `icloudExclusionsScript` → `icloud-exclusions.sh` (JSON args via env vars)
- `provision-wallpapers` per-wallpaper loop → `configs/provision-wallpaper.sh`
- `install-bun-packages` entry iteration → `home/install-bun-packages.sh`
- `provision-dev-repos` per-repo loop → `dev-repos-provision.sh`
- `macos-set-gui-env-path` PATH dedup → `macos-set-gui-env.sh` + `macos-set-gui-env-path.sh`

**Rule**: when adding a new split-pattern inline script, extract the pure-shell body to `src/scripts/` first, then wrap it in Nix with environment variable injection or `builtins.replaceStrings` for Nix-evaluated values.

The cross-platform no-embedding invariant, shared-file rule, and `__TOKEN__` convention are canonical in `embedded-content.instructions.md`; the boundaries above are the Nix-side exceptions.

## Argument convention for extracted scripts

- **All extracted inline scripts must accept inputs via positional arguments, not environment variables.** This keeps reasoning local and makes each script testable in isolation.
- `src/scripts/services/caddy-trust.sh` historically uses `NUCLEUS_REPO_ROOT` (an environment variable) for backward compatibility. New scripts must use positional arguments instead.
- **Helper scripts in `src/scripts/` (e.g. `register-host-age-key.sh`, `install-prek-hooks.sh`) use `--repo-root <path>` flags, not bare positional args.** Call sites in `src/scripts/apply.sh` must use the flag form. This prevents recurring bugs where a bare path is passed to a script that expects `--repo-root`.
- **Store-path args for external commands.** Activation scripts that invoke external tools (e.g. `jq`, `sops`, `age`) receive them as Nix store-path arguments (e.g. `_jq_bin="$1"`) and MUST invoke them via the variable (e.g. `"$_jq_bin"`), never as bare command names. This prevents "command not found" failures in minimal PATH environments. Check step 16 enforces that every `_X_bin` positional-arg declaration has at least one command-like usage.
- **Activation tool resolution (step 17).** The `activation-tool-resolution` check (step 17) scans activation scripts under `src/scripts/` for bare external command invocations that are NOT resolved via a store-path arg variable or an explicit `PATH=` prepend. The only sanctioned `PATH` use is a deliberate `PATH=` prepend where a tool must be visible to itself or child processes (e.g. bun, rustup, cargo). ShellCheck cannot verify command availability at activation time, so this custom check is the guard. Step 17 has no suppression mechanism — it skips comment lines entirely and reports all violations unconditionally. If a legitimate bare command is flagged, fix it by passing the tool as a store-path arg (preferred) or adding a `PATH=` prepend whose value contains a `_bin`-suffixed variable.

## Relative pathing convention

All scripts that source other files (libraries, configs, etc.) MUST derive their directory via SCRIPT_DIR and source via SCRIPT_DIR-relative paths. This makes scripts work from any cwd, prevents `CDPATH` interference, and resolves symlinks to physical paths (matching nix store resolution).

Standard form:

```sh
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/relative/path"
```

- Use `pwd -P` to resolve symlinks to physical paths.
- Use `CDPATH=''` to prevent the `CDPATH` environment variable from interfering with `cd`.
- Never use bare `$(dirname "$0")` in a source line; always pair with a SCRIPT_DIR assignment at the top of the script.
- For scripts in `scripts/` that resolve via `$_self` (symlink-safe), use `dirname -- "$_self"` instead of `dirname -- "$0"`.

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

## Sorting

- Package lists (e.g. `sharedPackages`, `environment.systemPackages`, `home.packages`) must be sorted alphabetically.
- Shell alias attrsets must be sorted alphabetically by alias name.
- `extraGroups` lists must be sorted alphabetically.
- `nix.settings.experimental-features` lists must be sorted alphabetically.
- Sort `case` branch labels, environment variable blocks, and any other unordered list-like constructs alphabetically.
- Do not sort items whose order is semantically significant: `boot.initrd.availableKernelModules`, ordered `imports` lists where one module precedes another by design.
- Do not sort `case` branches whose matching order is semantically significant (e.g. a catch-all `*` branch must remain last).
- Avoid repository-brand prefixes (for example `nucleus*`) in new Nix identifiers unless the prefix is required for cross-module disambiguation or external integration points.

## Portability and safety

- Keep scripts non-interactive by default unless that is their purpose.
- Prefer explicit error handling, predictable exit codes, and idempotent operations.
- Do not assume Bash-only features in `.sh` unless you require Bash and document that requirement.
- Prefer full cmdlet names over aliases in committed PowerShell scripts.

## Privilege-gating policy

Any code that checks whether it holds a privilege (sudo/root on POSIX; Administrator/elevated on Windows) follows this rule. A privilege is "required" only when the operation cannot succeed without it; a script that never needs the privilege is unaffected.

1. **Default (all `src/` code, and any non-user-facing path):** if the privilege is required but unavailable, **hard-error** (exit non-zero with a clear message). No warn-and-continue on a privilege gap. Continuing the operation *without* the privilege is also forbidden — attempting to proceed (e.g. falling back to a degraded non-privileged path) is not allowed. Hard-error is the only acceptable outcome.
2. **User-facing exception (`scripts/` only — the `nucleus-*` CLI set, NOT `src/scripts/`, `src/platforms/*/scripts/`, `src/hosts/*/`):** when an operation *requires* a privilege that the current process lacks, the script **escalates** to obtain it (POSIX: `sudo` re-exec / prefix; Windows: `RunAs` self-elevation). Only **warn-and-skip if escalation is genuinely impossible** (no `sudo` binary, UAC cancelled). If already privileged, proceed directly. This rule is scoped to *privilege-requiring operations only* — a user-facing script that never needs the privilege is unaffected and must not be forced to escalate. This rule replaces prior warn-and-skip behavior for cases where the script already gates on a missing item (e.g. `svc` system-domain).
3. **Inverse family — hard-refuse when already elevated (NOT warn-and-skip):** scripts that *refuse to run already-elevated* because they manage escalation internally (`scripts/bootstrap.sh`, `scripts/bootstrap.ps1`, `src/scripts/apply.sh`, `src/hosts/Windows/apply.ps1`). The outcome is a **hard refusal** (non-zero exit), not a warning.
   - **Windows admin-normal provisioning (no non-admin fallback):** writing to `%ProgramData%\nucleus\bin` (agent-host-shell setup, scheduled-task registration) runs under `RunAs` self-elevation, like POSIX `sudo`. No non-admin fallback path. Do not assume a non-admin case for Windows provisioning.
4. **Non-escalatable privileges (documented exceptions, keep warn-and-skip):**
   - macOS Full Disk Access (TCC privacy grant — cannot be obtained via sudo).
   - `nucleus-apply health-check` diagnostic reporting (its purpose is to surface gaps, not act).
   - `Invoke-VMSetup.ps1` WHPX detection (informational capability probe, not a gate).
5. **Applies to all platforms** (macOS, NixOS, Windows).

**Separate concern — Jellyfin admin token:** the Jellyfin app-level admin token (`.Policy.IsAdministrator`) is NOT covered by this policy and is NOT a warn-and-skip exception. A missing admin token normally means the user has not yet configured an admin Jellyfin account for themselves; if they lack admin they must not configure library items at all. Such code must **hard-error** (exit non-zero / `throw`), not warn-and-skip. This is a configuration-prerequisite check, not an escalation case.

## PowerShell conventions

### File naming

When adding or renaming standalone PowerShell entry points, use PascalCase and an approved `Verb-Noun` form (e.g. `Get-SystemInventory.ps1`).

The `scripts/` directory is the exception: helper scripts there keep the paired shell basename so `.sh` and `.ps1` stay aligned. That means `bootstrap.sh` pairs with `bootstrap.ps1`, `check-sh.sh` pairs with `check-sh.ps1`, and `check-pwsh.ps1` is a separate entry point for PowerShell linting (PSScriptAnalyzer) — not the Windows twin of `check-sh.sh`.

For reusable Windows modules under `src/platforms/Windows/modules/`, align the filename with the exported function name and prefer a single exported `Verb-Noun` function per file. If a module is renamed, update the dot-sourcing paths in `src/hosts/Windows/apply.ps1` in the same change. Collection-operating functions must use collection-indicating singular nouns — see `pwsh-lint-policy.instructions.md` (`PSUseSingularNouns`, anti–naive-de-pluralization).

If a PowerShell file exports multiple functions or none, keep it in `src/platforms/Windows/modules/` as a utility module and name the file for its shared purpose.

### Here-string extraction

The no-embedding invariant, shared cross-platform content rule, token convention, and exceptions are canonical in `embedded-content.instructions.md`. The mechanical details:

When extracting inline PowerShell here-strings from `src/platforms/Windows/modules/` into standalone scripts:

- Extract the script body to `src/platforms/Windows/modules/scripts/<name>.ps1`.
- In the caller, read it with: `Get-Content -Raw (Join-Path -Path $PSScriptRoot -ChildPath "..\scripts\<name>.ps1")`
- From any module subdirectory (`user/`, `system/`, `editors/`), `..\scripts\` resolves to `modules/scripts/`.
- For double-quote here-strings (`@"..."@`) with expanded variables, use token replacement: `$content = (Get-Content -Raw ...) -replace '__TOKEN__', $value`.
- Single-quote here-strings (`@'...'@`) can be read directly with no replacement needed.

### Explicit Parameter Passing

**All PowerShell functions must enforce caller awareness through explicit parameters.**

- **Mandatory behavioral parameters**: parameters controlling state changes (`Enabled`, `Users`, `Activated`, etc.) must be `[Parameter(Mandatory)]`. Do not default to `$true` or assume the current user.
- **No path auto-derivation**: never auto-derive `RepoRoot`, `ModuleDir`, `ConfigDir`, or other paths from `$PSScriptRoot`. Callers must pass them explicitly so they are aware of which paths will be modified.
- **Explicit user context always**: functions touching user profiles or home directories must have explicit `-Username` or `-Users` parameters. Never silently default to the current user or auto-discover users from the filesystem.
- **Remove dead paths**: this repository does not carry deprecated parameters, conditional migration paths, or old configuration formats. Remove the old path entirely and document the breaking change in examples and commit messages. See `AGENTS.md` — no in-code migration cleanup; execute one-off host cleanup before merge, never persist migration steps in the repo.
- **Complete function signatures**: every function signature must show all mandatory parameters in its `.SYNOPSIS` and `.EXAMPLE` sections so callers know what they are required to pass.

## Library purity

Library files (under `src/scripts/lib/`) are pure function/constant definitions. The same rules apply by analogy to Windows PowerShell helper modules under `src/platforms/Windows/modules/scripts/`.

1. **No top-level side effects on import.** A lib file defines functions and variables only — never execute commands at import time. No `set -eu` at the top level (only inside function bodies). No auto-invocation at end of file.
2. **No Nix placeholders.** Lib files must never contain `__TOKEN__`-style placeholders for Nix `builtins.replaceStrings`. All data enters via function parameters.
3. **Nix must not `builtins.readFile` lib files.** Nix modules source lib files at runtime (`. "$REPO_ROOT/src/scripts/lib/..."`) rather than inlining them at build time.
4. **Data from Nix goes to the consumer script first, then to lib via function args.** The consumer (activation script, service script, or standalone Nix-derived script) receives data from Nix through its own parameters or token substitution, then passes it to lib functions as arguments.

### Exception

A lib file may be embedded via `builtins.readFile` when it contains a clean function definition (no tokens, no env var dependencies) and is wrapped into a standalone script (e.g., a launchd daemon script) that executes independently. The embedded lib must remain pure — all external inputs arrive as function arguments from the wrapping code.

## Simplification patterns

Apply these patterns when maintaining scripts under `src/scripts/`:

- **Tiny libs (<20 lines, single caller)**: When a lib file provides only 1-2 variable definitions or one small function used by a single caller, inline the content directly into the caller and delete the lib file.
- **Trivial scripts (<10 lines, simple if/command check)**: Inline into the parent Nix activation string via `${builtins.readFile ...}` instead of maintaining a separate file.
- **Console user boilerplate (MacBook scripts)**: When multiple scripts independently probe `/dev/console` for UID/username, extract into a shared function under `src/scripts/lib/macos-console-user.sh`.
- **Service script helper duplication**: When two daemon scripts define identical small functions (e.g., `require_command`), extract to `src/scripts/lib/require-command.sh` and prepend at Nix build time.
- **Shared symlink convergence logic**: When scripts share structural overlap (iterate find results → remove stale → create missing), extract into `src/scripts/lib/symlink-convergence.sh`.
- **Nix prepend pattern**: For scripts built via `pkgs.writeShellScript` or activation strings, prepend lib content at build time: `(builtins.readFile ../scripts/lib/foo.sh) + (builtins.readFile ../scripts/lib/main-script.sh)` — removes the runtime sourcing path dependency.

## CWD independence — all `nucleus-*` commands must work from any working directory

Repository root resolution goes through `derive_repo_root()` in `src/scripts/lib/lib.sh` (priority order: `NUCLEUS_REPO_ROOT` environment variable → `<SYSTEM root>/repo-root` system file (macOS `/Library/Application Support/nucleus/repo-root`, NixOS `/var/lib/nucleus/repo-root`; POSIX all-process parity with Windows Machine scope) → `SCRIPT_DIR` offset walk checking `src/flake.nix`, then `.nucleus-repo-root` marker in the store tree → `git rev-parse` fallback).

`writeNucleusShellApplication` in `src/flake.nix` bakes `.nucleus-repo-root` into each nucleus app store tree at build time from eval-time `NUCLEUS_REPO_ROOT` (forwarded by `apply.sh` through `run_nix_as_root`). `src/modules/repo-root-file.nix` materializes `/etc/nucleus/repo-root` on macOS and NixOS during apply. `posix-security.nix` adds `Defaults env_keep += "NUCLEUS_REPO_ROOT"` so `sudo` preserves the variable when the invoking shell already has it.

Scripts must not assume the current working directory is inside the repository. Use `derive_repo_root()` or the `NUCLEUS_REPO_ROOT` environment variable for any path that resolves files relative to the repo root. Script-specific `--repo-root` flags (e.g. `replica-sync.sh`) are acceptable as additional manual overrides but must not be the sole mechanism for normal operation.

## Centralized daemon/service refresh

All program/daemon/service killing, refresh, and restart operations must go through centralized library functions:

- **macOS**: `src/scripts/lib/macos-launch-services.sh` (`refresh_*` functions)
- **Windows**: `src/platforms/Windows/modules/Set-NucleusService.ps1`

Do not inline killall/Stop-Service commands in activation blocks or individual scripts. This centralizes control per OS and prevents redundant kills in the same activation run.

For macOS activation blocks that need daemon refresh, use wrapper scripts under `src/platforms/macOS/scripts/` (or `src/scripts/lib/macos-launch-services.sh` directly when inlined) that source the library and call the appropriate `refresh_*` function. Invoke via the activation bundle subprocess pattern.

## Runtime configuration (`nucleus-config`)

Runtime toggles live at `~/.local/state/nucleus/config.json` (outside `~/.config/` so changes survive rebuilds). All toggles default to `true` when the file or key is absent, enforced by the implementation in `scripts/config.sh` / `scripts/config.ps1`.

Services read the config file directly (not via `nucleus-config`) for early-boot compatibility, following the same pattern on both POSIX and Windows.

When adding a toggle: add a default entry to the `DEFAULTS`/`$Defaults` map in both script implementations, then update consuming code to read the key (defaulting to `true`).

## PowerShell linting

`scripts/check-pwsh.ps1` splits work across the check and test pipelines because PSScriptAnalyzer is slow:

| Pipeline | Step | Flags | What runs |
| -------- | ---- | ----- | --------- |
| `check` (pre-commit) | 2 `powershell-lint` | `-SkipStep PSSA` | Parser syntax validation only |
| `test` (pre-push) | 2 `powershell-lint-test` | `-SkipStep Syntax -Settings test-PSScriptAnalyzerSettings.psd1` | PSScriptAnalyzer only (full rule set) |

Standalone `nucleus-check pwsh` runs both phases (no `-SkipStep`). Settings files: `scripts/check-PSScriptAnalyzerSettings.psd1` (when PSSA runs outside the test pipeline) and `scripts/test-PSScriptAnalyzerSettings.psd1` (test step 2). Do not configure rule exclusions in the checker script itself.

Always exclude `PSUseBOMForUnicodeEncodedFile` in settings files — UTF-8 without BOM is the repository standard (`.editorconfig`).

Verb-Noun and collection-singular naming policy: `pwsh-lint-policy.instructions.md`.

## Terminology in Examples

**Use canonical usernames in all code examples and documentation:**

- **`admin`**: represents the primary/elevated user in examples. Use this for any context where the primary user is required or most common (e.g. `-PrimaryUsername 'admin'`, `-Users @('admin')`).
- **`guest`**: represents any secondary or unprivileged user. Use when examples need to show multi-user scenarios (e.g. `-Users @('admin', 'guest')`).

## Tooling alignment

- Keep script behavior consistent with CI, `AGENTS.md`, and prompt guidance.
- If a script wraps project tooling, keep the underlying canonical commands discoverable in docs and config instead of hiding the real workflow.
- When script location or behavior changes, re-check `.github/workflows/ci.yml`, `.vscode/settings.json`, and any prompt or instruction files that reference it.

## apply.sh health-check subcommand SOPS identity resolution

`scripts/apply.sh` (the `health-check` subcommand) must export `SOPS_AGE_KEY_FILE` pointing to `/etc/sops/age/machine.txt` (the machine age key written by `deriveHostAgeKey`) before its `sops -d` probe loop, since `sops` does not search that path by default. Without this, `sops` falls through to GPG, which may not have the secret key in the keyring at health-check time.

See the `check_secret_health()` function in `scripts/apply.sh` (the `health-check` subcommand) for the implementation.

## Template placeholder convention

When using `builtins.replaceStrings` to substitute tokens in config/script source files, the placeholder token in the source file MUST use the format `__UPPERCASE_WITH_DOUBLE_UNDERSCORES__` (e.g., `__USERNAME__`, `__NIX_INDEX_BIN__`). Bare uppercase tokens like `USERNAME` are not permitted — they are indistinguishable from real code or misspelled variables.

Exception: well-known mechanical transformations such as `"~"` → home directory, URL percent-encoding, and path separator conversion (`/` → `\`) are not template placeholders and do not need this convention.

## Apple SDK enhancement pattern

The Apple SDK is enhanced with symlinks for Xcode toolchain shims that nixpkgs does not bundle by default. The pattern spans three files:

- `src/modules/lib/apple-sdk-tools.nix` maps xcrun shim names to nixpkgs derivations (or null). Returns `allTools` and `symlinkFarmTools` (filtered non-null). Attribute names containing `+` must be quoted: `"c++"`, `"clang++"`, `"flex++"`, `"c++filt"`.
- `src/modules/lib/apple-sdk-enhanced.nix` uses `pkgs.symlinkJoin` to merge the original apple-sdk with a `runCommand` layer adding `usr/bin/` symlinks from the tool mapping.
- Nix environment module (`env-catalog.nix`) sets `DEVELOPER_DIR` and `SDKROOT` to the enhanced derivation.
- `src/hosts/MacBook/activation.nix` runs `macos-remove-command-line-tools.sh` (install tree only; receipts are SIP-protected) then `xcode-select --switch` on the enhanced SDK.

## macOS platform policy

macOS-specific defaults sync, nix-darwin activation hooks, launchd service management, pmset power policy, and sops-nix LaunchAgent async behaviour are documented in `macos-service-hardening.instructions.md`. Nix authors editing MacBook host modules should consult that file for launchd label naming, EX_CONFIG recovery, and sops polling barriers.

## Shell module conventions

**zsh alias-vs-function precedence**

In zsh, aliases are expanded during the parsing phase, **before** function lookup. This means a `shellAliases` entry with the same name as a function will silently shadow the function — the function's body never executes.

Consequence: never add a `shellAliases` / `programs.zsh.shellAliases` entry whose name matches a function defined in `initContent` or `initExtra`. The canonical example is thefuck: `eval $(thefuck --alias)` defines a `fuck` shell function that captures history and auto-executes corrections; adding `fuck = "thefuck"` as an alias would shadow that function with a bare binary invocation that neither executes the fix nor records it in history.

## Shell history exclusion

All managed shells exclude two history features:

| Feature | zsh | PowerShell (POSIX) | PowerShell (Windows) | cmd.exe |
| --------- | ----- | --------------------- | ----------------------- | --------- |
| Ignore space-prefixed commands | `setopt HIST_IGNORE_SPACE` | `-AddToHistoryHandler { ... }` | Same | No equivalent |
| Ignore consecutive duplicates | `setopt HIST_IGNORE_DUPS` | `-HistoryNoDuplicates` | Same | No equivalent |

File locations: zsh in `src/scripts/shell/init.zsh` (embedded by `src/modules/shell.nix` `initContent`); PowerShell in `src/scripts/shell/profile.ps1` (PSReadLine block, embedded by `src/modules/pwsh.nix` on POSIX, read by `Sync-ShellProfile.ps1` on Windows); cmd.exe documented limitation in `src/hosts/Windows/user/shell.dsc.yml`.

When adding a new shell, enable the equivalent: bash `HISTCONTROL=ignorespace:ignoredups`; fish `fish_history` or custom function; nushell `$env.config.shell_integration.history.exclude_patterns`; cmd.exe no equivalent.

## Machine age key auto-registration

The `apply.sh` dispatcher calls `generate_ssh_host_key_if_needed` then `register_host_age_key_if_needed` before `darwin-rebuild`/`nixos-rebuild`.

`generate_ssh_host_key_if_needed`:

- Checks for `/etc/ssh/ssh_host_ed25519_key`; returns immediately if present (idempotent).
- If absent, runs `sudo env "PATH=$PATH" ssh-keygen -A` (explicit PATH finds Nix-wrapped openssh from `mkApplyApp` `runtimeInputs`). Fails fast on error.
- Only called from Darwin and NixOS branches (have sudo + `/etc/ssh/`).

`register_host_age_key_if_needed`:

- Derives machine age public key via `ssh-to-age -i` from `/etc/ssh/ssh_host_ed25519_key.pub`. If already in `.sops.yaml`, no-op.
- If new: inserts before `# -- machine keys end; personal SSH backup key below --` marker via `awk`, then rewraps all SOPS files with `sops updatekeys --yes`.
- Prints `git add`/`git commit` commands but does not commit automatically; operator must commit updated `.sops.yaml` and rewrapped secrets.
- Requires primary GPG key in keyring (`gpg --import` before first apply); fails with clear error and hint if GPG unavailable.
- `ssh-to-age`, `sops`, `openssh`, `git` provided by `mkApplyApp` `runtimeInputs` in `flake.nix`; no separate install needed.

Windows equivalent: `Register-HostAgeKey` in `src/platforms/Windows/modules/secrets/Register-HostAgeKey.ps1`, called when `$EnableHostAgeKeyRegistration` is `$true`.

## Pre-provision key adoption semantics

`ssh-key-adopt` (POSIX) and the SSH fingerprint tracking block in `Sync-NucleusSecretFile` (Windows) flush the SSH agent whenever the recorded fingerprint differs from the newly materialized one. The guard intentionally omits a "manifest must be non-empty" pre-condition to cover three cases:

- **Manifest absent, key present** (first provision): agent flushed, evicting manually pre-placed keys.
- **Manifest exists, key rotated**: agent flushed, removing the stale cached entry.
- **Manifest exists, key unchanged**: fingerprints match → no flush (idempotent).

Do not add `[ -n "$old_fingerprint" ]` (POSIX) or `$oldSshFingerprint -ne ''` (Windows) guards — they would silently skip the flush on first provision, leaving stale keys in the agent when the managed key is newer.

## Lockfile management

The repository uses a consolidated lockfile at `src/lockfiles/lockfile.json` to pin tool and package versions across all package managers.

### Schema

| Key | Format | Description |
| ---------------- | --------------------------------- | ---------------------------------------- |
| `scoop` | `string → string` | Scoop package name → version |
| `cargo-binstall` | `string → string` | Cargo crate name → version |
| `bun` | `string → string` | Bun package name → version |
| `uv` | `string → string`; VCS pins as `{source, rev}` object | Uv package name → version |
| `rustup` | `string → string` | Rust toolchain → date |
| `winget` | `string → string` | WinGet package ID → version |
| `vscode` | `string → string` | VS Code extension ID → version |
| `homebrew` | `object with brews/casks/masApps` | Homebrew formula/cask/MAS name → version |
| `ollama` | `string → string` | Ollama model name → digest hash |

All sections are required but may be empty (`{}`).

### Homebrew (no native lockfile)

Homebrew's `brew bundle` has no native lockfile. Formula, cask, and MAS version pins live under the `homebrew` key. Activation runs `brew bundle --force` from nix-darwin's generated Brewfile; the lockfile provides the audit trail.

### Updating

Use `scripts/update.sh` / `scripts/update.ps1` to update the lockfile. For Nix-managed packages, regenerate `src/flake.lock` with `nix flake lock` from `src/`.

The `uv` updater writes plain version strings and would clobber VCS object pins (e.g. `ext.discord-music-rpc` `{source, rev}`); both `bump-lockfile.sh` and `bump-lockfile.ps1` skip `.uv[<pkg>]` entries whose value is an object. Keep VCS-pinned uv packages as objects and preserve that guard.

## Validation

- Nix files can be syntax-checked locally with `nix-instantiate --parse <file>` or `nix flake check` (requires Nix to be installed).
- Because Nix is not available on Windows development machines, prefer small, isolated changes and rely on CI or a Linux/macOS machine for full evaluation.
- If `flake.lock` is absent or stale, run `nix flake lock` from `src/` before applying any configuration.

## Build artifact cleanup

After any `nix build`, `nix run ... -o`, or `nixos-generators`, run `scripts/gc.sh` (POSIX) or `scripts/gc.ps1` (Windows) to remove `result` / `result-*` symlinks from the repo root. Use `--dry-run` / `-WhatIf` for a preview.

Cleanup is integrated into `scripts/check.sh` and `scripts/check.ps1` in dry-run mode — stale artifacts cause the check to fail.

## What to avoid

- Do not inline long option lists that are already defined in a dedicated module (e.g. do not duplicate package lists in both `core.nix` and a host file).
- Do not commit `result` symlinks or `*.drv` paths.
- Do not guess or fabricate third-party tool behavior. When a bug or unexpected behavior involves an upstream tool (CamillaDSP, Jellyfin, nixpkgs, etc.), consult its source code or official documentation before reasoning about the root cause. Fabricated upstream semantics are not acceptable.
- Do not use `builtins.fetchTarball` for inputs that should be pinned through the flake lock.
- `substituteInPlace --replace` is deprecated — nixpkgs maps it to `--replace-warn`, which prints a warning and succeeds when the pattern does not match (a silent no-op trap). Use `--replace-fail` when the match is mandatory.
