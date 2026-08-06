#!/usr/bin/env bash
# VS Code config symlinks activation.
# Called by home-manager activation symlink-vscode-config.
# Provides: ensure_file_symlink, ensure_dir_symlink (from symlink-hardening.sh)

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../lib/symlink-hardening.sh"

_vsym_repo_root="$1"
_vsym_config_dir="$2"
_vsym_stable_base="$3"
_vsym_insiders_base="$4"
_vsym_keybindings_file="$5"
_vsym_chat_language_models_file="$6"
_vsym_jq_bin="$7"

if [ -z "$_vsym_repo_root" ] || [ ! -d "$_vsym_repo_root" ]; then
  _vsym_repo_root="${NUCLEUS_REPO_ROOT:?VS Code: NUCLEUS_REPO_ROOT not set; run via apply.sh}"
fi

if [ -z "$_vsym_config_dir" ] || [ ! -d "$_vsym_config_dir" ]; then
  echo "VS Code: config dir not found: $_vsym_config_dir" >&2
  exit 1
fi

for _vsym_base_dir in "$_vsym_stable_base" "$_vsym_insiders_base"; do
  ensure_file_symlink "$_vsym_config_dir/settings.json"    "$_vsym_base_dir/settings.json"
  ensure_file_symlink "$_vsym_config_dir/$_vsym_keybindings_file" "$_vsym_base_dir/keybindings.json"

  # chatLanguageModels is merge-copied rather than symlinked so that
  # per-machine Ollama model entries added by VS Code directly are
  # preserved across activations while repo-source entries are refreshed.
  _chat_lm_repo="$_vsym_config_dir/$_vsym_chat_language_models_file"
  _chat_lm_path="$_vsym_base_dir/chatLanguageModels.json"
  if [ -L "$_chat_lm_path" ]; then
    _nucleus_unprotect_symlink "VS Code" "$_chat_lm_path"
    rm "$_chat_lm_path"
  fi
  if [ -s "$_chat_lm_path" ] 2>/dev/null; then
    # shellcheck disable=SC2016 # reason: jq filter body must not be expanded by shell
    if ! "$_vsym_jq_bin" -s \
      '.[0] as $existing | reduce .[1][] as $item ($existing; (map(.name) | index($item.name)) as $idx | if $idx then .[$idx] = $item else . + [$item] end)' \
      "$_chat_lm_path" "$_chat_lm_repo" > "$_chat_lm_path.tmp" 2>"$_chat_lm_path.jqerr"; then
      echo "VS Code: warning — jq merge failed for $_chat_lm_path, keeping existing." >&2
      cat "$_chat_lm_path.jqerr" >&2
      rm -f "$_chat_lm_path.tmp" "$_chat_lm_path.jqerr"
    else
      mv "$_chat_lm_path.tmp" "$_chat_lm_path"
      rm -f "$_chat_lm_path.jqerr"
    fi
  else
    cp "$_chat_lm_repo" "$_chat_lm_path"
  fi

  ensure_file_symlink "$_vsym_config_dir/mcp.json"         "$_vsym_base_dir/mcp.json"
  ensure_file_symlink "$_vsym_config_dir/tasks.json"       "$_vsym_base_dir/tasks.json"
  ensure_dir_symlink  "$_vsym_config_dir/snippets"         "$_vsym_base_dir/snippets"
  ensure_dir_symlink  "$_vsym_config_dir/prompts"          "$_vsym_base_dir/prompts"
  ensure_dir_symlink  "$_vsym_config_dir/profiles"         "$_vsym_base_dir/profiles"
  # Copilot Chat stores memories under a deep per-extension subpath;
  # the repo uses a flat alias so the directory is easy to navigate.
  ensure_dir_symlink  "$_vsym_config_dir/copilot-memories" \
    "$_vsym_base_dir/globalStorage/github.copilot-chat/memory-tool/memories"
done
