# shellcheck shell=sh
# src/scripts/lib.sh — Shared library for nucleus POSIX shell scripts.
#
# Source this file at the top of any POSIX shell script under scripts/ or
# src/scripts/ after setting SCRIPT_DIR so REPO_ROOT can be derived
# automatically when needed.
#
# Usage:
#   SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
#   . "${SCRIPT_DIR}/../src/scripts/lib.sh"

# resolve_nucleus_root — Print the absolute path of the nucleus repository root.
#
# Resolution order:
#   1. $HOME/.config/nucleus/repo-root file (first line, if directory exists)
#   2. git rev-parse --show-toplevel (if inside a git working tree)
#   3. $HOME/dev/nucleus (fallback)
resolve_nucleus_root() {
  _rnr_config_file="$HOME/.config/nucleus/repo-root"
  if [ -f "$_rnr_config_file" ]; then
    _rnr_root="$(cat "$_rnr_config_file")"
    if [ -n "$_rnr_root" ] && [ -d "$_rnr_root" ]; then
      printf '%s\n' "$_rnr_root"
      return 0
    fi
  fi
  if _rnr_git_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    if [ -n "$_rnr_git_root" ] && [ -d "$_rnr_git_root" ]; then
      printf '%s\n' "$_rnr_git_root"
      return 0
    fi
  fi
  printf '%s\n' "$HOME/dev/nucleus"
}
