# Weekly garbage collection for Nix VM artifacts, build outputs, and caches.
set -eu

# Use REPO_ROOT from Nix-set env var, with runtime fallback.
_repo_root="${REPO_ROOT}"
if [ -z "$_repo_root" ] || [ ! -d "$_repo_root" ]; then
  _repo_root="${NUCLEUS_REPO_ROOT:?gc: NUCLEUS_REPO_ROOT not set; run via apply.sh}"
fi

if [ ! -f "$_repo_root/scripts/gc.sh" ]; then
  echo "gc: scripts/gc.sh not found at $_repo_root; skipping weekly GC"
  exit 1
fi

# Weekly GC is space-reclaim only; skip model pulls and skip any operations
# that would block the background launchd job (like waiting for Ollama).
# GC script handles tool availability checks internally.
exec "$_repo_root/scripts/gc.sh"
