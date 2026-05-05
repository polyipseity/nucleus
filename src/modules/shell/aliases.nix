# modules/shell/aliases.nix — Shared interactive shell aliases for all hosts.
#
# Keep keys strictly alphabetical so diffs stay deterministic and accidental
# duplicate alias intent is easy to detect during review.
{
  gs = "git status -sb";
  ll = "eza -la";
}
