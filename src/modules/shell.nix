# modules/shell.nix — Interactive shell configuration shared across all managed hosts.
# Sets up direnv (with nix-direnv for cached devShell evaluation), fish, zoxide
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

  programs.fish = {
    enable = true;
    shellAliases = {
      gs = "git status -sb"; # compact status: branch + ahead/behind
      ll = "eza -la";        # long listing with hidden files via eza
    };
  };

  # zoxide: a faster 'cd' that learns frequently used directories.
  # Integrates with both fish and zsh so 'z <query>' works in either shell.
  programs.zoxide = {
    enable = true;
    enableFishIntegration = true;
    enableZshIntegration = true;
  };

  programs.zsh = {
    autosuggestion.enable = true;    # fish-like inline history suggestions
    enable = true;
    enableCompletion = true;          # tab completion via compinit
    shellAliases = {
      gs = "git status -sb";
      ll = "eza -la";
    };
    syntaxHighlighting.enable = true; # command colouring (valid = green, etc.)
  };
}
