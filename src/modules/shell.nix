# modules/shell.nix — Interactive shell configuration shared across all managed hosts.
#
# Keeps shell aliases and environment variables in dedicated fragments to make
# ordering checks and targeted reviews straightforward.
{ ... }:
let
  # Dedicated alias/env fragments keep list-like attrsets isolated so sort order
  # can be audited without scanning unrelated shell options.
  shellAliases = import ./shell/aliases.nix;
  sessionVariables = import ./shell/env.nix;
in
{
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
    autosuggestion.enable = true;     # inline history suggestions
    enable = true;
    enableCompletion = true;          # tab completion via compinit
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
    # The Python ban wrappers follow; they must remain as functions (not aliases)
    # so they can emit multi-line guidance via heredoc.
    initContent = ''
      # pay-respects: register the shell hook so `f` replays the last failed
      # command with the corrected invocation suggested by pay-respects.
      # The generated function captures shell history and runs the corrected
      # command via eval so the fix is both executed and saved to shell history.
      eval "$(pay-respects zsh --alias)"

      # Intercept python/python3 invocations and warn about system-wide Python ban.
      # These are functions, not aliases, so they can provide helpful context.
      python() {
        cat >&2 << 'EOF'
nucleus: system-wide Python is banned to prevent accidental modifications.
         Use one of these approaches instead:
         - nix develop     (activate project devShell with scoped Python)
         - uv run <cmd>    (run Python via uv package manager)
         - uv venv         (create per-project venv managed by uv)
         - ./venv/bin/python (use pre-existing project venv)
EOF
        return 1
      }

      python3() {
        python "$@"
      }

      # Intercept pip/pip3 invocations and warn about system-wide pip ban.
      # Remind users that modifying system Python breaks system dependencies.
      pip() {
        cat >&2 << 'EOF'
nucleus: system-wide pip is banned to prevent breaking system dependencies.
         Use one of these approaches instead:
         - nix develop     (activate project devShell with scoped Python+pip)
         - uv pip install  (use uv to manage project dependencies)
         - uv venv         (create per-project venv managed by uv)
         - ./venv/bin/pip  (use pre-existing project venv)
EOF
        return 1
      }

      pip3() {
        pip "$@"
      }
    '';
  };

  home.sessionVariables = sessionVariables;
}
