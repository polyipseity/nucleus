# modules/agents.nix — Declarative ~/.agents directory symlink for all POSIX hosts.
#
# Creates a whole-directory symlink at ~/.agents pointing to the live
# src/modules/configs/agents/ tree in the repo checkout.  Every file written
# by a coding agent under ~/.agents/ therefore appears immediately as an
# unstaged git diff, keeping user-level agent instructions under version control.
#
# Activation reads the repo root from:
#   1. $NUCLEUS_REPO  (set by apply.sh before the rebuild call)
#   2. ~/.config/nucleus/repo-root  (written by apply.sh, survives the sudo boundary)
# Both paths mirror the pattern used by vscodeSymlinks in editors.nix.
#
# Migration safety:
#   - Correct symlink  → no-op.
#   - Wrong symlink    → remove and recreate.
#   - Real directory   → fail fast with an actionable message (no silent merge).
{ lib, ... }:
{
  home.activation = {
    # -------------------------------------------------------------------------
    # agentsSymlink
    # Creates ~/.agents as a symlink into src/modules/configs/agents/ so coding
    # agents write directly into the managed repo tree.  Relies on the repo root
    # being available via $NUCLEUS_REPO or ~/.config/nucleus/repo-root (written
    # by apply.sh before the rebuild so the value survives the sudo boundary).
    # Fails fast when ~/.agents is a real directory to prevent silent data loss;
    # the operator must merge existing content and remove the directory manually.
    # -------------------------------------------------------------------------
    agentsSymlink = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      set -eu

      # Resolve the repo root so the activation can construct an absolute path
      # to src/modules/configs/agents/ regardless of where the repo is checked
      # out.  $NUCLEUS_REPO is set by apply.sh; the file fallback survives the
      # sudo boundary that darwin-rebuild / nixos-rebuild cross.
      _as_repo_root_file="$HOME/.config/nucleus/repo-root"
      if [ -n "''${NUCLEUS_REPO:-}" ]; then
        _as_repo_root="$NUCLEUS_REPO"
      elif [ -f "$_as_repo_root_file" ]; then
        _as_repo_root="$(cat "$_as_repo_root_file")"
      else
        echo "nucleus: agentsSymlink: repo root not set; run via apply.sh or export NUCLEUS_REPO." >&2
        exit 1
      fi

      _as_agents_dir="$_as_repo_root/src/modules/configs/agents"
      if [ ! -d "$_as_agents_dir" ]; then
        echo "nucleus: agentsSymlink: agents config dir not found: $_as_agents_dir" >&2
        exit 1
      fi

      _as_link="$HOME/.agents"
      if [ -L "$_as_link" ]; then
        if [ "$(readlink "$_as_link")" = "$_as_agents_dir" ]; then
          :  # Correct symlink — no-op.
        else
          # Wrong target (e.g. leftover from a previous checkout path): replace.
          rm "$_as_link"
          ln -s "$_as_agents_dir" "$_as_link"
          echo "nucleus: agentsSymlink: updated $HOME/.agents -> $_as_agents_dir"
        fi
      elif [ -d "$_as_link" ]; then
        # Real directory: fail fast to prevent silent data loss.  The operator
        # must manually merge any wanted content into src/modules/configs/agents/
        # and remove the directory before re-running apply.
        echo "nucleus: agentsSymlink: $HOME/.agents is a real directory — merge its content into src/modules/configs/agents/ and remove it, then re-run apply." >&2
        exit 1
      else
        ln -s "$_as_agents_dir" "$_as_link"
        echo "nucleus: agentsSymlink: linked $HOME/.agents -> $_as_agents_dir"
      fi
    '';
  };
}
