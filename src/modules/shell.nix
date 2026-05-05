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
  };

  home.sessionVariables = sessionVariables;
}
