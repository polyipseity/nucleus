# modules/shell/aliases.nix — Shared interactive shell aliases for all hosts.
#
# Keep keys strictly alphabetical so diffs stay deterministic and accidental
# duplicate alias intent is easy to detect during review.
{ }: {
  # --- Git aliases ---
  # Naming conventions:
  # - Prefix = base git command (all `git log` aliases start with `-gl`).
  # - `-gca*` = amend (every alias starting with `-gca` expands to `git commit --amend ...`).
  # - No casing distinction (case-insensitive on Windows).
  # - Double letter = more: more verbose, more forceful, or full form.
  "-g" = "git";
  "-ga" = "git add";
  "-gap" = "git add -p";
  "-gb" = "git branch";
  "-gba" = "git branch -a";
  "-gbd" = "git branch -d";
  "-gbdd" = "git branch -D";
  "-gbm" = "git branch -m";
  "-gc" = "git commit";
  "-gca" = "git commit --amend";
  "-gcaa" = "git commit -a --amend";
  "-gcam" = "git commit --amend -m";
  "-gcl" = "git clone";
  "-gclean" = "git clean -fdn";
  "-gcleanf" = "git clean -fd";
  "-gcm" = "git commit -m";
  "-gcma" = "git commit -am";
  "-gco" = "git checkout";
  "-gcob" = "git checkout -b";
  "-gd" = "git diff";
  "-gdc" = "git diff --cached";
  "-gds" = "git diff --stat";
  "-gf" = "git fetch";
  "-gfa" = "git fetch --all";
  "-gg" = "git grep";
  "-gl" = "git log --oneline --decorate --graph";
  "-gla" = "git log --oneline --decorate --graph --all";
  "-gll" = "git log --decorate --graph --show-signature --stat";
  "-glla" = "git log --decorate --graph --show-signature --stat --all";
  "-glp" = "git log --oneline --decorate --graph -p";
  "-gls" = "git log --oneline --decorate --graph --stat";
  "-gm" = "git merge";
  "-gma" = "git merge --abort";
  "-gmnff" = "git merge --no-ff";
  "-gp" = "git push";
  "-gpf" = "git push --force-with-lease";
  "-gpff" = "git push --force";
  "-gpl" = "git pull";
  "-gplo" = "git pull origin";
  "-gplr" = "git pull --rebase";
  "-gpo" = "git push origin";
  "-gr" = "git remote";
  "-grb" = "git rebase";
  "-grba" = "git rebase --abort";
  "-grbc" = "git rebase --continue";
  "-grbi" = "git rebase -i";
  "-grbm" = "git rebase main";
  "-grbo" = "git rebase --onto";
  "-grbs" = "git rebase --skip";
  "-grev" = "git revert";
  "-grs" = "git reset";
  "-grsh" = "git reset --soft HEAD~";
  "-grshh" = "git reset --hard HEAD~";
  "-grv" = "git remote -v";
  "-gs" = "git status -sb";
  "-gsh" = "git show";
  # Ghostscript PDF optimization presets.
  # CompatibilityLevel is pinned to 2.0 (latest as of 2026-05); bump when a
  # newer PDF compatibility target is released by Ghostscript.
  "-gs-pdf-opt-default" =
    "gs -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/default -dNOPAUSE -dQUIET -dBATCH";
  "-gs-pdf-opt-ebook" =
    "gs -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/ebook -dNOPAUSE -dQUIET -dBATCH";
  "-gs-pdf-opt-prepress" =
    "gs -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/prepress -dNOPAUSE -dQUIET -dBATCH";
  "-gs-pdf-opt-printer" =
    "gs -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/printer -dNOPAUSE -dQUIET -dBATCH";
  "-gs-pdf-opt-screen" =
    "gs -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/screen -dNOPAUSE -dQUIET -dBATCH";
  "-gss" = "git status";
  "-gst" = "git stash push";
  "-gstd" = "git stash drop";
  "-gstl" = "git stash list";
  "-gstp" = "git stash pop";
  "-gstsh" = "git stash show -p";
  "-gsw" = "git switch";
  "-gswc" = "git switch -c";
  "-gt" = "git tag";
  "-gtd" = "git tag -d";
  "-gtl" = "git tag -l";
  # --- Non-git aliases ---
  "-la" = "eza -la";
  "-ll" = "eza -la";
  # bun shortcuts — mirror the Windows bun function aliases in shell.ps1 managed block.
  # -ni/-nr/-nx are concise but unambiguous; `bun x` replaces npx for one-shot package execution.
  "-ni" = "bun install";
  "-nr" = "bun run";
  "-nx" = "bun x";
  # Terminal clearing — `cls` alias for cross-platform parity (Windows/PowerShell
  # and cmd.exe both use cls; this makes zsh accept it too).
  "cls" = "clear";
  "-v" = "nvim";
}
