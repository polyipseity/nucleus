# modules/shell/aliases.nix - Shared interactive shell aliases for all hosts.
#
# Keys stay alphabetical so diffs stay deterministic.
{ }:
#
# Long forms only wherever one exists. No long form: git clean -d, and the
# Ghostscript -sDEVICE/-d option prefixes.
{
  # Prefix = base git command, so every `git log` alias starts with -gl. Casing
  # carries no meaning (Windows is case-insensitive). A doubled letter means the
  # longer form: -nf is fmt, -nff is format.
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
  # suffix = ignore scope (none / x includes ignored / xx only ignored).
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
  # WHY: bare `git stash`, not `git stash push`: the default subcommand still
  # pushes and any stash subcommand works through args (`-gst list`).
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
  # CompatibilityLevel is pinned to 2.0; bump when Ghostscript ships a newer
  # PDF compatibility target.
  "-optimize-pdf-default" =
    "gs -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/default -dNOPAUSE -dQUIET -dBATCH";
  "-optimize-pdf-prepress" =
    "gs -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/prepress -dNOPAUSE -dQUIET -dBATCH";
  "-optimize-pdf-printer" =
    "gs -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/printer -dNOPAUSE -dQUIET -dBATCH";
  "-optimize-pdf-ebook" =
    "gs -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/ebook -dNOPAUSE -dQUIET -dBATCH";
  "-optimize-pdf-screen" =
    "gs -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/screen -dNOPAUSE -dQUIET -dBATCH";
  "-strip-metadata" = "exiftool -all=";
  "-la" = "eza --long --all";
  "-ll" = "eza --long --all";
  # -n is bare bun, each suffix maps to one subcommand. -no reads like a negation
  # but o is outdated. Excluded as unused: audit, info, init, patch, pm,
  # publish, repl, unlink.
  "-n" = "bun";
  "-na" = "bun add";
  "-nb" = "bun build";
  "-nc" = "bun create";
  "-nci" = "bun ci";
  "-ncl" = "bun clean";
  "-nf" = "bun fmt";
  "-nff" = "bun format";
  "-ni" = "bun install";
  "-nl" = "bun link";
  "-no" = "bun outdated";
  "-nr" = "bun run";
  "-nrm" = "bun remove";
  "-nt" = "bun test";
  "-nu" = "bun update";
  "-nup" = "bun upgrade";
  "-nw" = "bun why";
  "-nx" = "bun x";
  # Cross-platform parity: PowerShell and cmd.exe both use cls.
  "cls" = "clear";
  "-v" = "nvim";
}
