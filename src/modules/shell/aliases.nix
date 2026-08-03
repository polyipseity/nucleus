# modules/shell/aliases.nix — Shared interactive shell aliases for all hosts.
#
# Keep keys strictly alphabetical so diffs stay deterministic and accidental
# duplicate alias intent is easy to detect during review.
{ }:
#
# Policy: full form
# All option values MUST use long-form names (--patch, --all, --message, etc.)
# wherever a long form exists. Short-form single-letter flags are prohibited.
#
# Exceptions (options with no long-form equivalent):
# - git clean -d (no --directory long form in git clean)
# - Ghostscript -sDEVICE=/-d* options (option-type prefixes, not short flags)
{
  # --- Git aliases ---
  # Naming conventions:
  # - Prefix = base git command (all `git log` aliases start with `-gl`).
  # - `-gca*` = amend (every alias starting with `-gca` expands to `git commit --amend ...`).
  # - No casing distinction (case-insensitive on Windows).
  # - Double letter = more: more verbose, more forceful, or full form.
  "-g" = "git";
  "-ga" = "git add";
  "-gap" = "git add --patch";
  "-gb" = "git branch";
  "-gba" = "git branch --all";
  "-gbd" = "git branch --delete";
  "-gbdd" = "git branch --delete --force";
  "-gbm" = "git branch --move";
  "-gc" = "git commit";
  "-gca" = "git commit --amend";
  "-gcaa" = "git commit --all --amend";
  "-gcam" = "git commit --amend --message";
  "-gcl" = "git clone";
  # git clean matrix: prefix = force level (dry-run / force / double-force),
  # suffix = ignore scope (none / x include ignored / xx only ignored).
  "-gclean" = "git clean --dry-run -d";
  "-gcleanf" = "git clean --force -d";
  "-gcleanff" = "git clean --force --force -d";
  "-gcleanffx" = "git clean --force --force -d -x";
  "-gcleanffxx" = "git clean --force --force -d -X";
  "-gcleanfx" = "git clean --force -d -x";
  "-gcleanfxx" = "git clean --force -d -X";
  "-gcleanx" = "git clean --dry-run -d -x";
  "-gcleanxx" = "git clean --dry-run -d -X";
  "-gcm" = "git commit --message";
  "-gcma" = "git commit --all --message";
  "-gco" = "git checkout";
  "-gcob" = "git checkout --branch";
  "-gd" = "git diff";
  "-gdc" = "git diff --cached";
  "-gds" = "git diff --stat";
  "-gf" = "git fetch";
  "-gfa" = "git fetch --all";
  "-gff" = "git fetch --force";
  "-gg" = "git grep";
  "-gl" = "git log --oneline --decorate --graph";
  "-gla" = "git log --oneline --decorate --graph --all";
  "-gll" = "git log --decorate --graph --show-signature --stat";
  "-glla" = "git log --decorate --graph --show-signature --stat --all";
  "-glp" = "git log --oneline --decorate --graph --patch";
  "-gls" = "git log --oneline --decorate --graph --stat";
  "-gm" = "git merge";
  "-gma" = "git merge --abort";
  "-gmnff" = "git merge --no-ff";
  "-gp" = "git push";
  "-gpf" = "git push --force-with-lease";
  "-gpff" = "git push --force";
  "-gpl" = "git pull";
  "-gplf" = "git pull --force";
  "-gplo" = "git pull origin";
  "-gplr" = "git pull --rebase";
  "-gpo" = "git push origin";
  "-gr" = "git remote";
  "-grb" = "git rebase";
  "-grba" = "git rebase --abort";
  "-grbc" = "git rebase --continue";
  "-grbi" = "git rebase --interactive";
  "-grbm" = "git rebase main";
  "-grbo" = "git rebase --onto";
  "-grbs" = "git rebase --skip";
  "-grev" = "git revert";
  "-grs" = "git reset";
  "-grsh" = "git reset --soft HEAD~";
  "-grshh" = "git reset --hard HEAD~";
  "-grv" = "git remote --verbose";
  "-gs" = "git status --short --branch";
  "-gsh" = "git show";
  "-gss" = "git status";
  # WHY: bare `git stash` (not `push`): no-arg still pushes (default subcommand),
  # and any stash subcommand works via args (e.g. `-gst list`).
  "-gst" = "git stash";
  "-gstd" = "git stash drop";
  "-gstl" = "git stash list";
  "-gstp" = "git stash pop";
  "-gstsh" = "git stash show --patch";
  "-gsw" = "git switch";
  "-gswc" = "git switch --create";
  "-gt" = "git tag";
  "-gtd" = "git tag --delete";
  "-gtl" = "git tag --list";
  # --- Ghostscript PDF optimization presets ---
  # CompatibilityLevel is pinned to 2.0 (latest as of 2026-05); bump when a
  # newer PDF compatibility target is released by Ghostscript.
  "-gs-pdf-opt-default" =
    "gs -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/default -dNOPAUSE -dQUIET -dBATCH";
  "-gs-pdf-opt-prepress" =
    "gs -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/prepress -dNOPAUSE -dQUIET -dBATCH";
  "-gs-pdf-opt-printer" =
    "gs -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/printer -dNOPAUSE -dQUIET -dBATCH";
  "-gs-pdf-opt-ebook" =
    "gs -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/ebook -dNOPAUSE -dQUIET -dBATCH";
  "-gs-pdf-opt-screen" =
    "gs -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/screen -dNOPAUSE -dQUIET -dBATCH";
  # --- Non-git aliases ---
  "-la" = "eza --long --all";
  "-ll" = "eza --long --all";
  # bun shortcuts — mirror the Windows bun function aliases in profile.ps1 managed block.
  # -n is the bare bun command; -ni/-nr/-nx are concise but unambiguous; `bun x` replaces npx for one-shot package execution.
  "-n" = "bun";
  "-ni" = "bun install";
  "-nr" = "bun run";
  "-nx" = "bun x";
  # Terminal clearing — `cls` alias for cross-platform parity (Windows/PowerShell
  # and cmd.exe both use cls; this makes zsh accept it too).
  "cls" = "clear";
  "-v" = "nvim";
}
