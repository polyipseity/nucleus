# modules/shell/aliases.nix — Shared interactive shell aliases for all hosts.
#
# Keep keys strictly alphabetical so diffs stay deterministic and accidental
# duplicate alias intent is easy to detect during review.
{ }:
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
  # Ghostscript PDF optimization presets.
  # CompatibilityLevel is pinned to 2.0 (latest as of 2026-05); bump when a
  # newer PDF compatibility target is released by Ghostscript.
  gs-pdf-opt-default = "gs -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/default -dNOPAUSE -dQUIET -dBATCH";
  gs-pdf-opt-ebook = "gs -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/ebook -dNOPAUSE -dQUIET -dBATCH";
  gs-pdf-opt-prepress = "gs -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/prepress -dNOPAUSE -dQUIET -dBATCH";
  gs-pdf-opt-printer = "gs -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/printer -dNOPAUSE -dQUIET -dBATCH";
  gs-pdf-opt-screen = "gs -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/screen -dNOPAUSE -dQUIET -dBATCH";
  gst = "git status";
  la = "eza -la";
  ll = "eza -la";
  # bun shortcuts — mirror the Windows bun function aliases in shell.ps1 managed block.
  # ni/nr/nx are concise but unambiguous; `bun x` replaces npx for one-shot package execution.
  ni = "bun install";
  nr = "bun run";
  nx = "bun x";
  v = "nvim";
}
