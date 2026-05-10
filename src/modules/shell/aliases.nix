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
  gll = "git log --oneline --decorate --graph";
  gp = "git push";
  gpl = "git pull";
  gst = "git status";
  la = "eza -la";
  ll = "eza -la";
  # bun shortcuts — mirror the Windows bun function aliases in shell.ps1 managed block.
  # ni/nr/nx are concise but unambiguous; `bun x` replaces npx for one-shot package execution.
  ni = "bun install";
  nr = "bun run";
  nucleus-gc = "nix run ./src#gc";
  nucleus-health-check = "nix run ./src#health-check";
  nucleus-update = "nix run ./src#update";
  nx = "bun x";
  v = "nvim";
}
