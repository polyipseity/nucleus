# modules/shell/aliases.nix — Shared interactive shell aliases for all hosts.
#
# Keep keys strictly alphabetical so diffs stay deterministic and accidental
# duplicate alias intent is easy to detect during review.
{
  g = "git";
  ga = "git add";
  gc = "git commit";
  gca = "git commit --amend";
  gco = "git checkout";
  gd = "git diff";
  gl = "git log --oneline --decorate --graph";
  gp = "git push";
  gpl = "git pull";
  gs = "git status -sb";
  gst = "git status";
  la = "eza -la";
  ll = "eza -la";
  nucleus-gc = "nix run ./src#gc";
  nucleus-health-check = "nix run ./src#health-check";
  nucleus-update = "nix run ./src#update";
  v = "nvim";
}
