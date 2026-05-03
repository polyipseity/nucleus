{ ... }:
{
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    shellAliases = {
      gs = "git status -sb";
      ll = "eza -la";
    };
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
}
