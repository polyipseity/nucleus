# shellcheck shell=sh
# VS Code config symlinks activation.
# Called by home-manager activation vsCodeSymlinks.
# Provides: ensure_file_symlink, ensure_dir_symlink (from symlink-hardening-lib.sh)
#
# Tokens (replaced by Nix builtins.replaceStrings):
#   __REPO_ROOT__                    — repo checkout root
#   __VSCODE_STABLE_BASE_DIR__       — stable User data dir ($HOME/...)
#   __VSCODE_INSIDERS_BASE_DIR__     — insiders User data dir ($HOME/...)
#   __VSCODE_KEYBINDINGS_FILE__      — host-specific keybindings filename
#   __VSCODE_CHAT_LANGUAGE_MODELS_FILE__ — host-specific chat models filename
#   __JQ_BIN__                       — path to jq binary

set -eu

# Locate the live repo checkout so the activation can resolve the
# src/modules/configs/vscode/ path regardless of where the repo lives.
# $NUCLEUS_REPO_ROOT is set by apply.sh and forwarded through sudo.  The
# eval-time fallback covers home-manager activation, which runs as the
# user and does not inherit the sudo-level env var.
_vsym_repo_root="__REPO_ROOT__"
if [ -z "$_vsym_repo_root" ] || [ ! -d "$_vsym_repo_root" ]; then
  _vsym_repo_root="${NUCLEUS_REPO_ROOT:?VS Code: NUCLEUS_REPO_ROOT not set; run via apply.sh}"
fi

_vsym_config_dir="$_vsym_repo_root/src/modules/configs/vscode"
if [ ! -d "$_vsym_config_dir" ]; then
  echo "VS Code: config dir not found: $_vsym_config_dir" >&2
  exit 1
fi

for _vsym_base_dir in "__VSCODE_STABLE_BASE_DIR__" "__VSCODE_INSIDERS_BASE_DIR__"; do
  ensure_file_symlink "$_vsym_config_dir/settings.json"    "$_vsym_base_dir/settings.json"
  ensure_file_symlink "$_vsym_config_dir/__VSCODE_KEYBINDINGS_FILE__" "$_vsym_base_dir/keybindings.json"

  # chatLanguageModels is merge-copied rather than symlinked so that
  # per-machine Ollama model entries added by VS Code directly are
  # preserved across activations while repo-source entries are refreshed.
  _chat_lm_repo="$_vsym_config_dir/__VSCODE_CHAT_LANGUAGE_MODELS_FILE__"
  _chat_lm_path="$_vsym_base_dir/chatLanguageModels.json"
  if [ -L "$_chat_lm_path" ]; then
    _nucleus_unprotect_symlink "VS Code" "$_chat_lm_path"
    rm "$_chat_lm_path"
  fi
  if [ -s "$_chat_lm_path" ] 2>/dev/null; then
    if ! __JQ_BIN__ -s \
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
