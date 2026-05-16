# modules/shell.nix — Interactive shell configuration shared across all managed hosts.
#
# Keeps shell aliases and environment variables in dedicated fragments to make
# ordering checks and targeted reviews straightforward.
{ config, lib, pkgs, ... }:
let
  # Dedicated alias/env fragments keep list-like attrsets isolated so sort order
  # can be audited without scanning unrelated shell options.
  shellAliases = import ./shell/aliases.nix { };
  sessionVariables = import ./shell/env.nix;

  # Keep a user-scoped baseline toolchain available even in repositories that do
  # not ship direnv or Nix metadata. This preserves the "no direct system tool
  # invocation" policy while still giving unmanaged projects a predictable bun /
  # cargo / rustc / uv / prek bundle.
  defaultDevTools = pkgs.symlinkJoin {
    name = "default-dev-tools";
    paths = [
      pkgs.bun
      pkgs.cargo
      pkgs.prek
      pkgs.rustc
      pkgs.uv
    ];
  };

  # Publish the fallback toolchain path as a session variable so every managed
  # shell can reach the same user-scoped binaries without duplicating the store
  # path string in multiple helper functions.
  mergedSessionVariables = sessionVariables // {
    NUCLEUS_DEFAULT_DEV_BIN = "${defaultDevTools}/bin";
    NUCLEUS_DEFAULT_DEV_ENV = "1";
  };

  # Build wrapper commands that always target the canonical nucleus flake path,
  # making nucleus-* commands runnable from any working directory and any shell
  # (without relying on shell alias expansion state).
  mkNucleusCommand =
    name: app:
    pkgs.writeShellScriptBin name ''
      set -eu

      # Export rclone config passphrase from SOPS-managed secret so rclone
      # transparently uses config file encryption in all interactive and
      # scripted invocations.
      # WHY conditional: sops-nix materializes the file asynchronously (macOS
      # LaunchAgent) or inline (NixOS); skip silently if the secret file is
      # absent during early bootstrap before decryption completes.
      ${lib.optionalString config.nucleus.rclone.configPassEnabled ''
      if [ -s "${config.nucleus.rclone.configPassSecretPath}" ]; then
        export RCLONE_CONFIG_PASS="$(cat "${config.nucleus.rclone.configPassSecretPath}")"
      fi
      ''}

      exec nix --option warn-dirty false run ${config.home.homeDirectory}/dev/nucleus/src#${app} -- "$@"
    '';
in
{
  home.packages = [
    (mkNucleusCommand "nucleus-cloud-setup" "cloud-setup")
    (mkNucleusCommand "nucleus-gc" "gc")
    (mkNucleusCommand "nucleus-health-check" "health-check")
    (mkNucleusCommand "nucleus-replica-sync" "replica-sync")
    (mkNucleusCommand "nucleus-replica-reset" "replica-reset")
    (mkNucleusCommand "nucleus-update" "update")
  ];

  # direnv: automatically loads/unloads per-directory environments.
  # nix-direnv: caches nix-shell/flake devShells so re-entering a directory
  # does not trigger a full Nix evaluation each time.
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # zoxide: a faster 'cd' that learns frequently used directories.
  # Integrates with zsh so 'z <query>' works in interactive sessions.
  programs.zoxide = {
    enable = true;
    enableZshIntegration = true;
  };

  programs.zsh = {
    autosuggestion.enable = true; # inline history suggestions
    enable = true;
    enableCompletion = true; # tab completion via compinit
    shellAliases = shellAliases;
    syntaxHighlighting.enable = true; # command colouring (valid = green, etc.)

    # -----------------------------------------------------------------------
    # initContent: pay-respects shell integration + system-wide Python ban
    # -----------------------------------------------------------------------
    # pay-respects is initialised here rather than via a shell alias because
    # `eval "$(pay-respects zsh --alias)"` creates a zsh FUNCTION named `f`
    # that captures shell history and auto-executes the corrected command via
    # eval.  A plain alias (aliases.nix) would shadow the function — aliases
    # expand before functions in zsh — leaving `f` as a bare binary invocation
    # that neither executes the fix nor records it in history.
    # The build-tool ban wrappers follow; they must remain as functions (not aliases)
    # so they can emit multi-line guidance via heredoc and pass through when in a
    # devShell (DIRENV_DIR set) or via the managed default toolchain.
    initContent = ''
            # pay-respects: register the shell hook so `f` replays the last failed
            # command with the corrected invocation suggested by pay-respects.
            # The generated function captures shell history and runs the corrected
            # command via eval so the fix is both executed and saved to shell history.
            eval "$(pay-respects zsh --alias)"

            # home.sessionVariables does not reliably populate plain interactive
            # `zsh -i` sessions in every launch path, so export the fallback tool
            # coordinates here as well.  This keeps repositories without .envrc
            # usable even when the shell did not start as a login shell.
            export NUCLEUS_DEFAULT_DEV_BIN="${defaultDevTools}/bin"
            export NUCLEUS_DEFAULT_DEV_ENV="1"

            # Route managed development tools through either the active direnv
            # environment or the user-scoped default toolchain for repositories
            # that do not provide their own .envrc / nix develop entrypoint.
            __nucleus_run_managed_dev_tool() {
              _tool_name="$1"
              shift

              if [[ -n "''${DIRENV_DIR:-}" ]]; then
                command "$_tool_name" "$@"
                return $?
              fi

              if [[ -n "''${NUCLEUS_DEFAULT_DEV_BIN:-}" && -x "''${NUCLEUS_DEFAULT_DEV_BIN}/$_tool_name" ]]; then
                "''${NUCLEUS_DEFAULT_DEV_BIN}/$_tool_name" "$@"
                return $?
              fi

              return 127
            }

            # Python/pip are only allowed when a scoped environment is active.
            # This keeps system Python protected while preserving normal venv/
            # conda workflows.
            __nucleus_python_scope_active() {
              [[ -n "''${VIRTUAL_ENV:-}" || -n "''${CONDA_PREFIX:-}" ]]
            }

            # Intercept python/python3 invocations and warn about system-wide Python ban.
            # These are functions, not aliases, so they can provide helpful context.
            python() {
              if __nucleus_python_scope_active; then
                command python "$@"
                return $?
              fi
              cat >&2 << 'EOF'
      shell: system-wide Python is banned to prevent accidental modifications.
               Use one of these approaches instead:
               - nix develop     (activate project devShell with scoped Python)
               - uv run <cmd>    (run Python via uv package manager)
               - uv venv         (create per-project venv managed by uv)
               - ./venv/bin/python (use pre-existing project venv)
      EOF
              return 1
            }

            python3() {
              if __nucleus_python_scope_active; then
                command python3 "$@"
                return $?
              fi
              python "$@"
            }

            # Intercept pip/pip3 invocations and warn about system-wide pip ban.
            # Remind users that modifying system Python breaks system dependencies.
            pip() {
              if __nucleus_python_scope_active; then
                command pip "$@"
                return $?
              fi
              cat >&2 << 'EOF'
      shell: system-wide pip is banned to prevent breaking system dependencies.
               Use one of these approaches instead:
               - nix develop     (activate project devShell with scoped Python+pip)
               - uv pip install  (use uv to manage project dependencies)
               - uv venv         (create per-project venv managed by uv)
               - ./venv/bin/pip  (use pre-existing project venv)
      EOF
              return 1
            }

            pip3() {
              if __nucleus_python_scope_active; then
                command pip3 "$@"
                return $?
              fi
              pip "$@"
            }

            # Intercept system-wide bun/cargo/rustc/uv invocations.
            # These tools are installed globally for system package management only:
            #   bun    — installs global Node/JS ecosystem system packages
            #   cargo  — cargo-binstall installs Rust binary system packages
            #   rustc  — companion to cargo for compilation during binstall
            #   uv     — installs system-level Python tooling
            # Direct developer use of these system binaries is blocked.
            # When DIRENV_DIR is set, a direnv environment (devShell) is active and
            # its scoped binaries shadow the system tools; otherwise use the
            # managed default toolchain installed under the user's profile.
            bun() {
              __nucleus_run_managed_dev_tool bun "$@"
              _status=$?
              if [[ "$_status" -ne 127 ]]; then
                return "$_status"
              fi
              cat >&2 << 'EOF'
      shell: managed bun is unavailable right now.
               For development, use one of these managed entrypoints:
               - Enter a project directory with .envrc (direnv auto-loads the devShell)
               - Or use the user-scoped default toolchain installed by nucleus apply
               Shell shortcuts ni/nr/nx also work inside a devShell.
      EOF
              return 1
            }

            cargo() {
              __nucleus_run_managed_dev_tool cargo "$@"
              _status=$?
              if [[ "$_status" -ne 127 ]]; then
                return "$_status"
              fi
              cat >&2 << 'EOF'
      shell: managed cargo is unavailable right now.
               For Rust development, use one of these managed entrypoints:
               - Enter a project directory with .envrc (direnv auto-loads the devShell)
               - Or use the user-scoped default toolchain installed by nucleus apply
      EOF
              return 1
            }

            rustc() {
              __nucleus_run_managed_dev_tool rustc "$@"
              _status=$?
              if [[ "$_status" -ne 127 ]]; then
                return "$_status"
              fi
              cat >&2 << 'EOF'
      shell: managed rustc is unavailable right now.
               For Rust development, use one of these managed entrypoints:
               - Enter a project directory with .envrc (direnv auto-loads the devShell)
               - Or use the user-scoped default toolchain installed by nucleus apply
      EOF
              return 1
            }

            uv() {
              __nucleus_run_managed_dev_tool uv "$@"
              _status=$?
              if [[ "$_status" -ne 127 ]]; then
                return "$_status"
              fi
              cat >&2 << 'EOF'
      shell: managed uv is unavailable right now.
               For Python development, use one of these managed entrypoints:
               - Enter a project directory with .envrc (direnv auto-loads the devShell)
               - Or use the user-scoped default toolchain installed by nucleus apply
      EOF
              return 1
            }
    '';
  };

  home.sessionVariables = mergedSessionVariables;
}
