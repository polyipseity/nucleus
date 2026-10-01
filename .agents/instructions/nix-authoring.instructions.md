---
description: "Use when authoring or editing Nix files in src/: flake structure, module conventions, script builders (writeNucleusShellApplication), activation blocks, inline code extraction, and Nix-specific patterns."
name: "Nix Authoring"
applyTo: "src/**/*.nix, src/modules/**/*.nix, src/hosts/**/*.nix"
---

# Nix authoring

## Flake conventions

- Every input follows nixpkgs: `inputs.<name>.follows = "nixpkgs"`. Duplicate evaluations are a bug.
- Keep `username` and system strings in the `let` block at the top of `flake.nix`.
- `config.allowUnfree = true` only inside `mkPkgs`.
- Run `nix flake lock` from `src/` after adding or changing an input.
- `builtins.fetchTarball` is banned for inputs already pinned through the flake lock.

## Host conventions

- Every host module imports `../../modules/core.nix`. Both POSIX hosts import the `../../modules/posix` aggregator; `posix/security.nix` stays out of it because `security.sudo` is NixOS-only, and the NixOS host imports that module directly.
- Drivers, hardware modules, and kernel args belong in the host file, never a shared module. Shared modules must not hardcode paths under `src/hosts/`; declare an option and set it from each host entrypoint.
- Set `system.stateVersion` to the host's bootstrap-era value and never bump it automatically.
- Replace NixOS hardware stubs with the real `hardware-configuration.nix` from `nixos-generate-config` after the first install.

## Module conventions

- Guard NixOS-only options with `lib.mkIf` on `options ? environment` or equivalent, and guard `home.*` options the same way in Home Manager modules.
- No `with pkgs;` in a module-level attribute set.
- Home Manager `home.file` entries use `lib.optionalAttrs` with a `builtins.pathExists` guard.
- No implicit defaults, no auto-derived paths, no compatibility code. Give `lib.mkOption` a default only when it is obvious (`false` for a feature flag, `[ ]` for a list). Examples use `admin` for a primary or elevated user and `guest` for a secondary one.

## Nix file structure

Every `.nix` file inside a directory is named `default.nix`, and no `.nix` file sits next to a directory of the same name (`shell.nix` beside `shell/`). Both are enforced by check step 12 (`run_nix_file_structure`). A module file that needs a companion data directory lives inside that directory as `default.nix` and reaches the data by relative path (`workflowsDir = ..;`).

## Script builders

Always use `pkgs.writeNucleusShellApplication`, not `pkgs.writeShellApplication`. Exception: a technical constraint that prevents it, such as dynamic names in function context as in `cloud-drives.nix`, with a `# WHY:` comment.

- `scriptName`: repo-root-relative path without `.sh`. Paths under `scripts/` resolve through `scripts-bundle`, everything else through `script-tree`. The entry script is always at `$out/<scriptName>.sh`.
- `text`: inline body, with `PATH` set from `runtimeInputs`. For trivial scripts or host-specific values that block reuse.
- `extraEnv`: shell-escaped environment injection. Prefer positional args for standalone scripts; use `extraEnv` when several callers source the same body, so the body does not parse both `$1` and env vars.

`writeShellApplication` from nixpkgs has no `bundleDefault`, `extraEnv`, or `text`, so scripts built with it cannot source sibling libraries relative to `SCRIPT_DIR`.

### Values as positional args

Prefer positional CLI args over environment variables. Launchd agents take extra `ProgramArguments` elements and read them as `$1`, `$2`; activation hooks pass them in the activation string; a `home.file` wrapper that cannot take args hardcodes them in a `text` entry that ends with `exec '<pkg>/bin/cmd' '<value>' "$@"`.

A script that takes positional args also accepts the matching env var as a fallback: `VAR="${ENV_VAR_NAME:-${1:-default_value}}"`.

When a `.sh` under `src/scripts/` is both invoked via `scriptName` and sourced by another script, pass the values through `extraEnv`. Do not wrap a shared body in `text`; that duplicates `extraEnv`.

## Activation blocks

- Never source a library from `src/scripts/lib/` directly inside an activation block. The `REPO_ROOT` pattern couples activation timing to the layout and hides the script from analysis tools. Use an import wrapper under `src/scripts/lib/` and `builtins.readFile` that. A standalone script run for its side effects may call `builtins.readFile` itself; a thin library wrapper (no loops, no conditionals) may embed the library and call its functions inline.
- Substitute values into an embedded script with `builtins.replaceStrings` over `__UPPERCASE_WITH_DOUBLE_UNDERSCORES__` tokens. Never export shell variables before invoking the script; that bypasses PATH isolation and mixes compile-time with runtime. For tool paths, prepend a token-replaced bin directory to `PATH` inside the script (`src/scripts/services/jellyfin-sync.sh`).
- Comments must never contain a token placeholder string: `builtins.replaceStrings` rewrites every occurrence, comments included.
- Activation tool resolution (check step 11, `run_activation_tool_resolution`) fails a bare external command. Pass the tool as a store-path arg (`_jq_bin="$1"`, invoked as `"$_jq_bin"`) or prepend `PATH` deliberately for a tool child processes need. `run_store_path_arg_usage` also fails a `_X_bin` variable with no command-like usage.

The remaining activation rules (prohibited patterns, bundle layout, terminal activations) are in `activation-scripts.instructions.md`, and the no-embedding invariant plus the `__TOKEN__` convention are in `embedded-content.instructions.md`.

## When code needs its own file

Give a script its own file when it has real logic (loops, conditionals, data processing), dispatches to another command, or is a persistent daemon. Extract runtime imperative work (SOPS decryption, API calls, service polling) into an invocable script instead of inlining it in a Nix indented string.

Keep it inline when the loop structure is the Nix expression (per-entry `lib.concatMapStrings` over SOPS files, cloud mounts, wallpaper entries), the snippet is under 10 lines with Nix references, or the shell body is already extracted and only a token-replaced wrapper remains.

Extracted scripts take inputs as positional args, not environment variables. Helpers in `src/scripts/` use `--repo-root <path>` flags.

## Library purity

Libraries (`src/scripts/lib/`, `src/platforms/Windows/modules/scripts/`) hold only function and constant definitions: no top-level side effects on import, no `__TOKEN__` placeholders, and Nix does not `builtins.readFile` them. Data flows from Nix through the consumer script into the lib as function args.

## Simplification patterns

- A lib under 20 lines with a single caller belongs inline in that caller.
- A trivial script (under 10 lines) belongs inline in the activation string via `${builtins.readFile ...}`.
- Console-user boilerplate, service-helper duplication, and symlink convergence logic belong in `src/scripts/lib/` (`macos-console-user.sh`, `require-command.sh`, `symlink-convergence.sh`), never copy-pasted per script.

## Apple SDK

nixpkgs ships no Xcode toolchain shims, so the SDK is enhanced: `src/modules/lib/apple-sdk-tools.nix` maps xcrun shim names to derivations (quote attribute names containing `+`, such as `"c++"`, `"clang++"`, `"flex++"`, `"c++filt"`), `src/modules/lib/apple-sdk-enhanced.nix` merges them, `env-secrets.nix` points `DEVELOPER_DIR` and `SDKROOT` at the result, and `src/hosts/MacBook/activation.nix` runs `macos-remove-command-line-tools.sh` then `xcode-select --switch`.

## Validation

- `nix-instantiate --parse <file>` for a single file, `nix flake check` from `src/` for everything. If `flake.lock` is absent or stale, run `nix flake lock` first.
- After `nix build`, `nix run ... -o`, or `nixos-generators`, remove `result` and `result-*` symlinks with `scripts/gc.sh` / `scripts/gc.ps1`; `scripts/check.sh` / `scripts/check.ps1` do this in dry-run mode. Never commit them or a `*.drv` path.
- Do not duplicate an option list a dedicated module already defines, and do not guess third-party tool behavior: read the source or the docs before reasoning about a root cause.
- `substituteInPlace --replace` is deprecated and maps to `--replace-warn`, a silent no-op. Use `--replace-fail` when the match is mandatory.
