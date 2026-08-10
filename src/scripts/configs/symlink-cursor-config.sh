#!/usr/bin/env bash
# Bridges ~/.cursor/ to ~/.agents/ (shared agent assets) and
# src/users/<user>/cursor/ (Cursor-native JSON/hooks), and symlinks the IDE
# settings.json overlay into the Cursor User dir.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../lib/symlink-hardening.sh"
. "$SCRIPT_DIR/../lib/resolve-user-config.sh"
. "$SCRIPT_DIR/../lib/symlink-convergence.sh"

_scc_repo_root="$1"
_scc_username="$2"
if [ -n "$_scc_repo_root" ]; then
  export NUCLEUS_REPO_ROOT="$_scc_repo_root"
fi
_scc_label="cursor-config"

_scc_agents_dir="$HOME/.agents"
_scc_cursor_dir="$HOME/.cursor"

if [ ! -d "$_scc_agents_dir" ]; then
  echo "$_scc_label: $HOME/.agents not found — run symlink-agent-config first." >&2
  exit 1
fi

# Ensure ~/.cursor exists as a real (writable) directory.
if [ ! -d "$_scc_cursor_dir" ]; then
  mkdir "$_scc_cursor_dir"
  echo "$_scc_label: created $HOME/.cursor"
elif [ -e "$_scc_cursor_dir" ] && [ ! -d "$_scc_cursor_dir" ]; then
  echo "$_scc_label: $HOME/.cursor exists but is not a directory — remove it and re-run apply." >&2
  exit 1
fi

_scc_ensure_real_dir() {
  _erd_path="$1"
  if [ -L "$_erd_path" ]; then
    echo "$_scc_label: $_erd_path is a symlink — expected a real directory for managed file symlinks." >&2
    exit 1
  fi
  if [ ! -d "$_erd_path" ]; then
    mkdir "$_erd_path"
    echo "$_scc_label: created $_erd_path"
  fi
}

_scc_converge_mapped_file_symlinks() {
  _cms_source_dir="$1"
  _cms_source_suffix="$2"
  _cms_target_dir="$3"
  _cms_target_suffix="$4"

  _scc_ensure_real_dir "$_cms_target_dir"

  if [ -d "$_cms_source_dir" ]; then
    for _cms_source in "$_cms_source_dir"/*"$_cms_source_suffix"; do
      [ -f "$_cms_source" ] || continue
      _cms_base="$(basename "$_cms_source" "$_cms_source_suffix")"
      _cms_link="$_cms_target_dir/${_cms_base}${_cms_target_suffix}"
      if [ -L "$_cms_link" ]; then
        if [ "$(readlink "$_cms_link")" = "$_cms_source" ]; then
          continue
        fi
        _nucleus_unprotect_symlink "$_scc_label" "$_cms_link"
        rm "$_cms_link"
      elif [ -e "$_cms_link" ]; then
        echo "$_scc_label: $_cms_link is not a managed symlink — remove it and re-run apply." >&2
        exit 1
      fi
      ln -s "$_cms_source" "$_cms_link"
      _nucleus_protect_symlink "$_scc_label" "$_cms_link"
      echo "$_scc_label: linked $_cms_link -> $_cms_source"
    done
  fi

  if [ -d "$_cms_target_dir" ]; then
    find "$_cms_target_dir" -mindepth 1 -maxdepth 1 -type l | while IFS= read -r _cms_candidate; do
      _cms_ctarget="$(readlink "$_cms_candidate")"
      case "$_cms_ctarget" in
      "$_cms_source_dir"/*"$_cms_source_suffix")
        if [ ! -f "$_cms_ctarget" ]; then
          _nucleus_unprotect_symlink "$_scc_label" "$_cms_candidate"
          rm "$_cms_candidate"
          echo "$_scc_label: removed stale symlink $(basename "$_cms_candidate") (source removed)"
        fi
        ;;
      esac
    done
  fi
}

_scc_converge_folder_symlink() {
  _cfs_link="$1"
  _cfs_target="$2"

  if [ -L "$_cfs_link" ]; then
    if [ "$(readlink "$_cfs_link")" = "$_cfs_target" ]; then
      return 0
    fi
    _nucleus_unprotect_symlink "$_scc_label" "$_cfs_link"
    rm "$_cfs_link"
  elif [ -e "$_cfs_link" ]; then
    echo "$_scc_label: $_cfs_link is not a managed symlink — remove it and re-run apply." >&2
    exit 1
  fi
  ln -s "$_cfs_target" "$_cfs_link"
  _nucleus_protect_symlink "$_scc_label" "$_cfs_link"
  echo "$_scc_label: linked $_cfs_link -> $_cfs_target"
}

# Class A: shared agents assets under ~/.agents/.
_scc_converge_folder_symlink "$_scc_cursor_dir/skills" "$_scc_agents_dir/skills"

_scc_converge_mapped_file_symlinks \
  "$_scc_agents_dir/instructions" ".instructions.md" \
  "$_scc_cursor_dir/rules" ".mdc"

_scc_converge_mapped_file_symlinks \
  "$_scc_agents_dir/agents" ".agent.md" \
  "$_scc_cursor_dir/agents" ".md"

_scc_converge_mapped_file_symlinks \
  "$_scc_agents_dir/prompts" ".prompt.md" \
  "$_scc_cursor_dir/commands" ".md"

# Class B: Cursor-native entries from the first-level merged cursor overlay.
# settings.json is skipped here: it targets the IDE User dir (Class C), not
# ~/.cursor/.
_scc_overlay_skip_names="rules agents commands skills settings.json"
_nucleus_remove_stale_merged_symlinks \
  "$_scc_cursor_dir" "$_scc_username" "cursor" "$_scc_repo_root" "$_scc_label" "$_scc_overlay_skip_names"

_nucleus_converge_merged_config_symlinks \
  "$_scc_username" "cursor" "$_scc_repo_root" "$_scc_cursor_dir" "$_scc_label" \
  "" "-e" \
  "is not a managed symlink — merge any wanted content into the source entry and remove it, then re-run apply." \
  "$_scc_overlay_skip_names"

# Class C: Cursor IDE settings — symlink settings.json into the IDE User dir
# (separate from ~/.cursor/, which holds CLI-side config).
case "$(uname -s)" in
Darwin)
  _scc_ide_user_dir="$HOME/Library/Application Support/Cursor/User"
  ;;
Linux)
  _scc_ide_user_dir="$HOME/.config/Cursor/User"
  ;;
*)
  echo "$_scc_label: unsupported platform for Cursor IDE settings symlink: $(uname -s)" >&2
  exit 1
  ;;
esac
_scc_ide_settings="$(resolve_user_config_file "$_scc_username" "cursor" "settings.json")"
# check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
ensure_file_symlink "$_scc_ide_settings" "$_scc_ide_user_dir/settings.json"
