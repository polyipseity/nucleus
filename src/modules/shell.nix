{ ... }:
{
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.fish = {
    enable = true;
    shellAliases = {
      gs = "git status -sb";
      ll = "eza -la";
    };
  };

  programs.zoxide = {
    enable = true;
    enableFishIntegration = true;
    enableZshIntegration = true;
  };

  programs.zsh = {
    autosuggestion.enable = true;
    enable = true;
    enableCompletion = true;
    shellAliases = {
      gs = "git status -sb";
      ll = "eza -la";
    };
    syntaxHighlighting.enable = true;
  };
}
