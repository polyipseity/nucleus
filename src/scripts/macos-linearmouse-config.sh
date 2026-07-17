# Create out-of-store symlinks for LinearMouse runtime config files pointing
# into the repository tree.  Resolves the repo root at activation time so the
# link survives repo relocations and rebuilds without stale store paths.
#
# Environment variables:
#   REPO_ROOT — Nix-evaluated repo root (set by wrapper), falls back to
#               NUCLEUS_REPO_ROOT at runtime
set -eu

_ll_repo_root="${REPO_ROOT}"
if [ -z "$_ll_repo_root" ] || [ ! -d "$_ll_repo_root" ]; then
  _ll_repo_root="${NUCLEUS_REPO_ROOT:?LinearMouse: NUCLEUS_REPO_ROOT not set; run via apply.sh}"
fi
_ll_source="$_ll_repo_root/src/modules/configs/linearmouse/linearmouse.json"

mkdir -p "$HOME/.config/linearmouse"
mkdir -p "$HOME/Library/Application Support/linearmouse"
ln -sf "$_ll_source" "$HOME/.config/linearmouse/linearmouse.json"
ln -sf "$_ll_source" "$HOME/Library/Application Support/linearmouse/linearmouse.json"
