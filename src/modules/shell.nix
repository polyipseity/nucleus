# modules/shell.nix — Interactive shell configuration shared across all managed hosts.
# Sets up direnv (with nix-direnv for cached devShell evaluation), zoxide
# (smart directory jumping), and zsh with quality-of-life plugins.
{ ... }:
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
    shellAliases = {
      gs = "git status -sb";
      ll = "eza -la";
    };
    syntaxHighlighting.enable = true; # command colouring (valid = green, etc.)
  };
}
