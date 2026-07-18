# shellcheck shell=sh
# Assemble the effective gitignore from the managed global baseline and a
# user-writable overlay.  Run after linkGeneration so symlinks are ready.
set -eu

_git_ignore_global="$HOME/.config/git/ignore-global"
_git_ignore_user="$HOME/.config/git/ignore-user"
_git_ignore_effective="$HOME/.config/git/ignore"

if [ ! -f "$_git_ignore_user" ]; then
  cat > "$_git_ignore_user" <<'EOF'
    # User-specific Git ignore patterns.
    # Add one pattern per line; these are appended after ignore-global.
EOF
fi

{
  cat "$_git_ignore_global"
  printf '\n'
  cat "$_git_ignore_user"
} > "$_git_ignore_effective"
