# Create out-of-store symlinks for LinearMouse runtime config files pointing
# into the repository tree.  Resolves the repo root at activation time so the
# link survives repo relocations and rebuilds without stale store paths.
set -eu

_ll_repo_root='__REPO_ROOT__'
_ll_source="$_ll_repo_root/src/modules/configs/linearmouse/linearmouse.json"

mkdir -p "$HOME/.config/linearmouse"
mkdir -p "$HOME/Library/Application Support/linearmouse"
ln -sf "$_ll_source" "$HOME/.config/linearmouse/linearmouse.json"
ln -sf "$_ll_source" "$HOME/Library/Application Support/linearmouse/linearmouse.json"
