#!/usr/bin/env bash
# VS Code config symlinks activation.
# Called by home-manager activation symlink-vscode-config.
# Provides: ensure_file_symlink, ensure_dir_symlink (from symlink-hardening.sh)

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../lib/lib.sh"
. "$SCRIPT_DIR/../lib/symlink-hardening.sh"
. "$SCRIPT_DIR/../lib/resolve-user-config.sh"

_vsym_repo_root="$1"
_vsym_username="$2"
_vsym_stable_base="$3"
_vsym_insiders_base="$4"
_vsym_keybindings_file="$5"
_vsym_chat_language_models_file="$6"
_vsym_jq_bin="$7"

if [ -z "$_vsym_repo_root" ] || [ ! -d "$_vsym_repo_root" ]; then
  _vsym_repo_root="${NUCLEUS_REPO_ROOT:?VS Code: NUCLEUS_REPO_ROOT not set; run via apply.sh}"
fi
export NUCLEUS_REPO_ROOT="$_vsym_repo_root"

_vsym_settings="$(resolve_user_config_file "$_vsym_username" "vscode" "settings.json")"
_vsym_mcp="$(resolve_user_config_file "$_vsym_username" "vscode" "mcp.json")"
_vsym_tasks="$(resolve_user_config_file "$_vsym_username" "vscode" "tasks.json")"
_vsym_keybindings="$(resolve_user_config_file "$_vsym_username" "vscode" "$_vsym_keybindings_file")"
_vsym_chat_lm_repo="$(resolve_user_config_file "$_vsym_username" "vscode" "$_vsym_chat_language_models_file")"
_vsym_snippets="$(resolve_user_config_first_level_entry "$_vsym_username" "vscode" "snippets")"
_vsym_prompts="$(resolve_user_config_first_level_entry "$_vsym_username" "vscode" "prompts")"
_vsym_profiles=""
if _vsym_profiles_candidate="$(resolve_user_config_first_level_entry "$_vsym_username" "vscode" "profiles" 2>/dev/null)"; then
  _vsym_profiles="$_vsym_profiles_candidate"
fi
_vsym_copilot_memories="$(resolve_user_config_first_level_entry "$_vsym_username" "vscode" "copilot-memories")"

for _vsym_base_dir in "$_vsym_stable_base" "$_vsym_insiders_base"; do
  ensure_file_symlink "$_vsym_settings" "$_vsym_base_dir/settings.json"
  ensure_file_symlink "$_vsym_keybindings" "$_vsym_base_dir/keybindings.json"

  # chatLanguageModels is merge-copied rather than symlinked so that
  # per-machine Ollama model entries added by VS Code directly are
  # preserved across activations while repo-source entries are refreshed.
  _chat_lm_path="$_vsym_base_dir/chatLanguageModels.json"
  if [ -L "$_chat_lm_path" ]; then
    _nucleus_unprotect_symlink "VS Code" "$_chat_lm_path"
    rm "$_chat_lm_path"
  fi
  if [ -s "$_chat_lm_path" ] 2>/dev/null; then
    # shellcheck disable=SC2016 # reason: jq filter body must not be expanded by shell
    if ! "$_vsym_jq_bin" -s \
      '.[0] as $existing | reduce .[1][] as $item ($existing; (map(.name) | index($item.name)) as $idx | if $idx then .[$idx] = $item else . + [$item] end)' \
      "$_chat_lm_path" "$_vsym_chat_lm_repo" >"$_chat_lm_path.tmp" 2>"$_chat_lm_path.jqerr"; then
      warn -l "VS Code" "jq merge failed for $_chat_lm_path, keeping existing."
      cat "$_chat_lm_path.jqerr" >&2
      rm -f "$_chat_lm_path.tmp" "$_chat_lm_path.jqerr"
    else
      mv "$_chat_lm_path.tmp" "$_chat_lm_path"
      rm -f "$_chat_lm_path.jqerr"
    fi
  else
    cp "$_vsym_chat_lm_repo" "$_chat_lm_path"
  fi

  ensure_file_symlink "$_vsym_mcp" "$_vsym_base_dir/mcp.json"
  ensure_file_symlink "$_vsym_tasks" "$_vsym_base_dir/tasks.json"
  ensure_dir_symlink "$_vsym_snippets" "$_vsym_base_dir/snippets"
  ensure_dir_symlink "$_vsym_prompts" "$_vsym_base_dir/prompts"
  if [ -n "$_vsym_profiles" ] && [ -e "$_vsym_profiles" ]; then
    ensure_dir_symlink "$_vsym_profiles" "$_vsym_base_dir/profiles"
  fi
  # Copilot Chat stores memories under a deep per-extension subpath;
  # the repo uses a flat alias so the directory is easy to navigate.
  ensure_dir_symlink "$_vsym_copilot_memories" \
    "$_vsym_base_dir/globalStorage/github.copilot-chat/memory-tool/memories"
done
