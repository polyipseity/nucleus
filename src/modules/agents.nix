# modules/agents.nix — Declarative ~/.agents directory layout for all POSIX hosts.
#
# Creates ~/.agents/ as a real directory, then creates a per-entry symlink inside
# it for every top-level entry in src/modules/configs/agents/ except skills/.
# skills/ is excluded here because it is managed by agentsSkills (below) and may
# contain downloaded content that must not be committed (fetched / clawhub).
#
# This per-subdir layout replaces the old whole-directory symlink scheme.  The
# old scheme made ~/.agents an alias for the entire source tree, which prevented
# clawhub from writing fetched skill downloads into ~/.agents/skills/ without
# those writes entering the tracked repo tree.
#
# Activation reads the repo root from:
#   1. $NUCLEUS_REPO  (set by apply.sh before the rebuild call)
#   2. ~/.config/nucleus/repo-root  (written by apply.sh, survives the sudo boundary)
# Both paths mirror the pattern used by vscodeSymlinks in editors.nix.
#
# Migration safety:
#   - Old whole-dir symlink → removed automatically (all old-scheme symlinks
#     pointed at src/modules/configs/agents/; none were user-created).
#   - Correct per-subdir symlink  → no-op.
#   - Wrong per-subdir symlink    → remove and recreate.
#   - Real directory at sub-path  → fail fast with an actionable message.
#   - Stale per-subdir symlink    → removed (source entry no longer exists).
#
# agentsSkills (below) manages ~/.agents/skills/ independently.
{ lib, ... }:
{
  home.activation = {
    # -------------------------------------------------------------------------
    # agentsSymlink
    # Creates ~/.agents/ as a real directory and populates it with per-entry
    # symlinks for every top-level entry in src/modules/configs/agents/ except
    # skills/ (which is managed by agentsSkills so fetched clawhub downloads
    # land in a real, untracked directory rather than inside the repo tree).
    #
    # Migration: if ~/.agents is still the old whole-dir symlink it is removed
    # first; the activation then re-creates the structure as a real directory
    # with per-subdir symlinks.
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

      _as_agents_source="$_as_repo_root/src/modules/configs/agents"
      if [ ! -d "$_as_agents_source" ]; then
        echo "nucleus: agentsSymlink: agents config dir not found: $_as_agents_source" >&2
        exit 1
      fi

      _as_agents_dir="$HOME/.agents"

      # Migration: the old agentsSymlink scheme created ~/.agents as a single
      # whole-dir symlink pointing to _as_agents_source.  Remove it so a real
      # directory can be created in its place.  Any symlink at this path was
      # created by the old activation; user-created symlinks are not expected.
      if [ -L "$_as_agents_dir" ]; then
        rm "$_as_agents_dir"
        echo "nucleus: agentsSymlink: migrated from whole-dir symlink to per-subdir layout"
      elif [ -e "$_as_agents_dir" ] && [ ! -d "$_as_agents_dir" ]; then
        # Unexpected non-directory, non-symlink file: fail fast.
        echo "nucleus: agentsSymlink: $HOME/.agents exists but is not a directory or symlink — remove it and re-run apply." >&2
        exit 1
      fi

      # Ensure ~/.agents exists as a real (writable) directory.
      if [ ! -d "$_as_agents_dir" ]; then
        mkdir "$_as_agents_dir"
        echo "nucleus: agentsSymlink: created $HOME/.agents"
      fi

      # Remove stale per-subdir symlinks: any symlink in ~/.agents/ that once
      # pointed into _as_agents_source/ but whose source entry no longer exists.
      # This keeps ~/.agents/ free of dangling links after source entries are
      # removed from the repo.  skills/ is skipped — agentsSkills owns it.
      _as_stale_list="$(mktemp)"
      find "$_as_agents_dir" -mindepth 1 -maxdepth 1 -type l > "$_as_stale_list"
      while IFS= read -r _as_candidate; do
        _as_cname="$(basename "$_as_candidate")"
        [ "$_as_cname" = "skills" ] && continue
        _as_ctarget="$(readlink "$_as_candidate")"
        case "$_as_ctarget" in
          "$_as_agents_source"/*)
            # Managed per-subdir symlink: remove if its source no longer exists.
            if [ ! -e "$_as_ctarget" ] && [ ! -L "$_as_ctarget" ]; then
              rm "$_as_candidate"
              echo "nucleus: agentsSymlink: removed stale link for $_as_cname (source removed)"
            fi
            ;;
        esac
      done < "$_as_stale_list"
      rm -f "$_as_stale_list"

      # Create or update per-entry symlinks for every top-level source entry
      # except skills/ (managed independently by agentsSkills).
      _as_source_list="$(mktemp)"
      find "$_as_agents_source" -mindepth 1 -maxdepth 1 > "$_as_source_list"
      while IFS= read -r _as_entry; do
        _as_name="$(basename "$_as_entry")"
        # skills/ is managed by agentsSkills; skip it here to avoid conflicts
        # with the real directory that agentsSkills creates for fetched downloads.
        [ "$_as_name" = "skills" ] && continue
        _as_link="$_as_agents_dir/$_as_name"
        if [ -L "$_as_link" ]; then
          if [ "$(readlink "$_as_link")" = "$_as_entry" ]; then
            continue  # Correct symlink — no-op.
          fi
          # Wrong target (e.g. leftover from a previous checkout path): replace.
          rm "$_as_link"
          ln -s "$_as_entry" "$_as_link"
          echo "nucleus: agentsSymlink: updated $HOME/.agents/$_as_name -> $_as_entry"
        elif [ -e "$_as_link" ]; then
          # Real file or directory: fail fast to prevent silent data loss.
          echo "nucleus: agentsSymlink: $HOME/.agents/$_as_name is not a managed symlink — merge any wanted content into $_as_entry and remove it, then re-run apply." >&2
          exit 1
        else
          ln -s "$_as_entry" "$_as_link"
          echo "nucleus: agentsSymlink: linked $HOME/.agents/$_as_name -> $_as_entry"
        fi
      done < "$_as_source_list"
      rm -f "$_as_source_list"
    '';

    # -------------------------------------------------------------------------
    # agentsSkills
    # Creates ~/.agents/skills/ as a real (writable) directory, then creates a
    # per-skill symlink inside it for every skill subdirectory committed to
    # src/modules/configs/agents/skills/ (bundled / AGPL-compatible skills).
    #
    # Fetched skills (non-AGPL / clawhub-managed) are downloaded directly into
    # ~/.agents/skills/<name>/ by the post-apply sync step in apply.sh; they
    # are never committed to the repo and are not managed here.
    #
    # The skills/ tree is a real directory — not a symlink — so that:
    #   1. Bundled per-skill symlinks can coexist with fetched real dirs.
    #   2. clawhub can write into ~/.agents/skills/ without the writes landing
    #      inside the tracked repo tree (which would happen with a whole-dir
    #      symlink back to src/modules/configs/agents/skills/).
    #
    # Conflict safety: if a committed skill name collides with an existing real
    # directory in ~/.agents/skills/ (e.g. a fetched download), the activation
    # fails fast rather than silently overwriting the downloaded content.
    # -------------------------------------------------------------------------
    agentsSkills = lib.hm.dag.entryAfter [ "agentsSymlink" ] ''
      set -eu

      # Resolve the repo root (same mechanism as agentsSymlink above).
      _ask_repo_root_file="$HOME/.config/nucleus/repo-root"
      if [ -n "''${NUCLEUS_REPO:-}" ]; then
        _ask_repo_root="$NUCLEUS_REPO"
      elif [ -f "$_ask_repo_root_file" ]; then
        _ask_repo_root="$(cat "$_ask_repo_root_file")"
      else
        echo "nucleus: agentsSkills: repo root not set; run via apply.sh or export NUCLEUS_REPO." >&2
        exit 1
      fi

      _ask_skills_source="$_ask_repo_root/src/modules/configs/agents/skills"
      if [ ! -d "$_ask_skills_source" ]; then
        echo "nucleus: agentsSkills: skills source dir not found: $_ask_skills_source" >&2
        exit 1
      fi

      _ask_skills_dir="$HOME/.agents/skills"

      # Ensure ~/.agents/skills/ exists as a real directory so fetched clawhub
      # downloads can be written here without entering the tracked repo tree.
      if [ -L "$_ask_skills_dir" ]; then
        # Old whole-dir symlink to source/skills/ — remove so it becomes real.
        rm "$_ask_skills_dir"
        echo "nucleus: agentsSkills: migrated ~/.agents/skills from symlink to real directory"
      fi
      if [ ! -d "$_ask_skills_dir" ]; then
        mkdir -p "$_ask_skills_dir"
        echo "nucleus: agentsSkills: created $HOME/.agents/skills"
      fi

      # Remove stale per-skill symlinks: skill dirs that once existed in the
      # source but have since been removed from the repo.
      _ask_stale_list="$(mktemp)"
      find "$_ask_skills_dir" -mindepth 1 -maxdepth 1 -type l > "$_ask_stale_list"
      while IFS= read -r _ask_candidate; do
        _ask_cname="$(basename "$_ask_candidate")"
        _ask_ctarget="$(readlink "$_ask_candidate")"
        case "$_ask_ctarget" in
          "$_ask_skills_source"/*)
            # Managed per-skill symlink: remove if its source no longer exists.
            if [ ! -e "$_ask_ctarget" ] && [ ! -L "$_ask_ctarget" ]; then
              rm "$_ask_candidate"
              echo "nucleus: agentsSkills: removed stale skill link for $_ask_cname (source removed)"
            fi
            ;;
        esac
      done < "$_ask_stale_list"
      rm -f "$_ask_stale_list"

      # Create or update per-skill symlinks for every subdirectory committed to
      # src/modules/configs/agents/skills/.  Non-directory entries (.gitkeep etc.)
      # are skipped; only skill directories are linked.
      _ask_source_list="$(mktemp)"
      find "$_ask_skills_source" -mindepth 1 -maxdepth 1 -type d > "$_ask_source_list"
      while IFS= read -r _ask_skill_dir; do
        _ask_skill_name="$(basename "$_ask_skill_dir")"
        _ask_link="$_ask_skills_dir/$_ask_skill_name"
        if [ -L "$_ask_link" ]; then
          if [ "$(readlink "$_ask_link")" = "$_ask_skill_dir" ]; then
            continue  # Correct symlink — no-op.
          fi
          # Wrong target: replace symlink.
          rm "$_ask_link"
          ln -s "$_ask_skill_dir" "$_ask_link"
          echo "nucleus: agentsSkills: updated $HOME/.agents/skills/$_ask_skill_name -> $_ask_skill_dir"
        elif [ -d "$_ask_link" ]; then
          # Real directory in place of a committed skill — could be a fetched
          # download with the same name, or user data.  Fail fast to prevent
          # silent overwrites; the operator must resolve the conflict manually.
          echo "nucleus: agentsSkills: $HOME/.agents/skills/$_ask_skill_name is a real directory — if it is a fetched clawhub download for a skill that has been re-committed, remove it and re-run apply." >&2
          exit 1
        else
          ln -s "$_ask_skill_dir" "$_ask_link"
          echo "nucleus: agentsSkills: linked $HOME/.agents/skills/$_ask_skill_name -> $_ask_skill_dir"
        fi
      done < "$_ask_source_list"
      rm -f "$_ask_source_list"
    '';
  };
}
