---
description: "Use when authoring or editing Nix files in src/."
name: "Nix Authoring"
applyTo: "src/**/*.nix, src/modules/**/*.nix, src/hosts/**/*.nix"
---

# Nix authoring

# Upstream workarounds registry: .agents/instructions/upstream-workarounds.instructions.md

Every input follows nixpkgs (`inputs.<name>.follows = "nixpkgs"`). Keep `username` and system strings in the top `let` of `flake.nix`; `config.allowUnfree = true` only in `mkPkgs`. Run `nix flake lock` from `src/` after input changes; `builtins.fetchTarball` is banned for pinned inputs.

Every host module imports `../../modules/core.nix`. Both POSIX hosts import `../../modules/posix`; `posix/security.nix` stays out because `security.sudo` is NixOS-only and the NixOS host imports it. Drivers, hardware, and kernel args stay in host files; shared modules declare options instead of `src/hosts/` paths. Keep `system.stateVersion` at bootstrap value and never auto-bump. Replace stubs with `hardware-configuration.nix` from `nixos-generate-config` after first install.

Guard NixOS-only options with `lib.mkIf` on `options ? environment`, and `home.*` options similarly. No module-level `with pkgs;`; use `lib.optionalAttrs` plus `builtins.pathExists` for `home.file`. No implicit defaults, auto-derived paths, or compatibility code; `lib.mkOption` defaults only when obvious (`false`, `[ ]`). Examples use `admin` and `guest`. Every `.nix` file in a directory is `default.nix`, and none sits beside a same-named directory (step 12 `run_nix_file_structure`). A module with data lives in that directory as `default.nix` and reaches data relatively (`workflowsDir = ..;`).

Use `pkgs.writeNucleusShellApplication`, never `pkgs.writeShellApplication`, except for a real technical constraint (dynamic names in `cloud-drives.nix`) with `# WHY:`. `scriptName` is repo-relative without `.sh`; `scripts/` resolves through `scripts-bundle`, others through `script-tree`, entry at `$out/<scriptName>.sh`. `text` holds trivial or host-specific bodies; `extraEnv` injects shell-escaped values when several callers source one body. Prefer positional args. nixpkgs' builder lacks `bundleDefault`, `extraEnv`, and `text`, so it cannot source siblings via `SCRIPT_DIR`. A positional-arg script also accepts its env fallback (`VAR="${ENV_VAR_NAME:-${1:-default_value}}"`); a `src/scripts/` script invoked by `scriptName` and sourced elsewhere passes values via `extraEnv`, never a duplicated `text` wrapper.

Activation blocks never source `src/scripts/lib/` directly: use an import wrapper and `builtins.readFile`. A standalone side-effect script may call `readFile`; a thin wrapper may embed library functions. Substitute with `builtins.replaceStrings` over `__UPPERCASE_WITH_DOUBLE_UNDERSCORES__` tokens, never shell vars before invocation; comments must not contain tokens because every occurrence is rewritten. Step 11 rejects bare external commands: pass store paths as args (`_jq_bin="$1"`) or prepend `PATH` deliberately. Other rules: `activation-scripts.instructions.md` and `embedded-content.instructions.md`.

Extract real logic, dispatch, daemons, and runtime imperative work (SOPS, API, polling) into invocable scripts. Keep inline loops that are the Nix expression (`lib.concatMapStrings`), snippets under 10 lines with Nix references, and token-replaced wrappers. Extracted scripts take positional args; `src/scripts/` helpers also take `--repo-root <path>`. Libraries (`src/scripts/lib/`, `src/platforms/Windows/modules/scripts/`) hold only definitions: no top-level effects, no tokens, no Nix `readFile`. A lib under 20 lines with one caller belongs inline; a script under 10 lines belongs in an activation string. Shared boilerplate (`macos-console-user.sh`, `require-command.sh`, `symlink-convergence.sh`) stays in `src/scripts/lib/`.

nixpkgs ships no Xcode shims: `apple-sdk-tools.nix` maps xcrun names (quote `+` names such as `"c++"`, `"clang++"`, `"flex++"`, `"c++filt"`), `apple-sdk-enhanced.nix` merges, `env-secrets.nix` sets `DEVELOPER_DIR`/`SDKROOT`, and `MacBook/activation.nix` runs `macos-remove-command-line-tools.sh` then `xcode-select --switch`.

Validate with `nix-instantiate --parse <file>`, `nix flake check` from `src/`, and `nix flake lock` first when needed. Remove `result` and `result-*` with `scripts/gc.sh` / `.ps1`; never commit them or `*.drv`. Do not duplicate option lists or guess third-party behavior; read source or docs. `substituteInPlace --replace` is deprecated and silently maps to `--replace-warn`; use `--replace-fail`.
