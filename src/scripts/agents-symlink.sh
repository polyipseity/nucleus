# shellcheck shell=sh
# Sets up ~/.agents/ with per-entry symlinks into
# src/modules/configs/agents/.
# Requires: REPO_ROOT, AGENTS_CONFIG_RELATIVE_PATH env vars.
# Agent helpers (_nucleus_protect_symlink, _nucleus_unprotect_symlink,
# _nucleus_resolve_repo_root) must be sourced before this script.

_as_repo_root="$(_nucleus_resolve_repo_root "agents-config" "$REPO_ROOT")"

_as_agents_source="$_as_repo_root/$AGENTS_CONFIG_RELATIVE_PATH"
if [ ! -d "$_as_agents_source" ]; then
  echo "agents-config: agents config dir not found: $_as_agents_source" >&2
  exit 1
fi

_as_agents_dir="$HOME/.agents"

# Ensure ~/.agents exists as a real (writable) directory.
if [ ! -d "$_as_agents_dir" ]; then
  mkdir "$_as_agents_dir"
  echo "agents-config: created $HOME/.agents"
elif [ -e "$_as_agents_dir" ] && [ ! -d "$_as_agents_dir" ]; then
  # Unexpected non-directory file: fail fast.
  echo "agents-config: $HOME/.agents exists but is not a directory — remove it and re-run apply." >&2
  exit 1
fi

# Remove stale per-subdir symlinks: any symlink in ~/.agents/ that once
# pointed into _as_agents_source/ but whose source entry no longer exists.
# This keeps ~/.agents/ free of dangling links after source entries are
# removed from the repo.  skills/ is skipped — agentsSkills owns it.
find "$_as_agents_dir" -mindepth 1 -maxdepth 1 -type l | while IFS= read -r _as_candidate; do
  _as_cname="$(basename "$_as_candidate")"
  [ "$_as_cname" = "skills" ] && continue
  _as_ctarget="$(readlink "$_as_candidate")"
  case "$_as_ctarget" in
    "$_as_agents_source"/*)
      # Managed per-subdir symlink: remove if its source no longer exists.
      if [ ! -e "$_as_ctarget" ] && [ ! -L "$_as_ctarget" ]; then
        _nucleus_unprotect_symlink "agents-config" "$_as_candidate"
        rm "$_as_candidate"
        echo "agents-config: removed stale link for $_as_cname (source removed)"
      fi
      ;;
  esac
done

# Create or update per-entry symlinks for every top-level source entry
# except skills/ (managed independently by agentsSkills).
find "$_as_agents_source" -mindepth 1 -maxdepth 1 | while IFS= read -r _as_entry; do
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
    _nucleus_unprotect_symlink "agents-config" "$_as_link"
    rm "$_as_link"
    ln -s "$_as_entry" "$_as_link"
    _nucleus_protect_symlink "agents-config" "$_as_link"
    echo "agents-config: updated $HOME/.agents/$_as_name -> $_as_entry"
  elif [ -e "$_as_link" ]; then
    # Real file or directory: fail fast to prevent silent data loss.
    echo "agents-config: $HOME/.agents/$_as_name is not a managed symlink — merge any wanted content into $_as_entry and remove it, then re-run apply." >&2
    exit 1
  else
    ln -s "$_as_entry" "$_as_link"
    _nucleus_protect_symlink "agents-config" "$_as_link"
    echo "agents-config: linked $HOME/.agents/$_as_name -> $_as_entry"
  fi
done

# Create the ~/.config/opencode/opencode.jsonc symlink to the repo-hosted
# user config. Resolved at activation time (rather than via Nix-level
# mkOutOfStoreSymlink) so the link still works after the repo root path
# changes between rebuilds.
mkdir -p "$HOME/.config/opencode"
_as_opencode_source="$_as_repo_root/$AGENTS_CONFIG_RELATIVE_PATH/opencode.user.jsonc"
_as_opencode_link="$HOME/.config/opencode/opencode.jsonc"
if [ -L "$_as_opencode_link" ]; then
  if [ "$(readlink "$_as_opencode_link")" != "$_as_opencode_source" ]; then
    rm "$_as_opencode_link"
  fi
elif [ -e "$_as_opencode_link" ]; then
  echo "agents-config: $_as_opencode_link exists and is not a managed symlink — remove or back it up, then re-run apply." >&2
  exit 1
fi
if [ ! -e "$_as_opencode_link" ]; then
  ln -s "$_as_opencode_source" "$_as_opencode_link"
  echo "agents-config: linked $HOME/.config/opencode/opencode.jsonc"
fi
