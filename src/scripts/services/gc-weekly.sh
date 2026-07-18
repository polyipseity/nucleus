# Weekly garbage collection for Nix VM artifacts, build outputs, and caches.
set -eu

# __REPO_ROOT__ is substituted at build time by Nix.  Fallback env vars
# support manual/standalone invocation (e.g. via apply.sh which sets
# NUCLEUS_REPO_ROOT).
_repo_root="__REPO_ROOT__"
if [ -z "$_repo_root" ] || [ ! -d "$_repo_root" ]; then
  _repo_root="${REPO_ROOT:-}"
  if [ -z "$_repo_root" ] || [ ! -d "$_repo_root" ]; then
    _repo_root="${NUCLEUS_REPO_ROOT:?gc: NUCLEUS_REPO_ROOT not set; run via apply.sh}"
  fi
fi

if [ ! -f "$_repo_root/scripts/gc.sh" ]; then
  echo "gc: scripts/gc.sh not found at $_repo_root; skipping weekly GC"
  exit 1
fi

# Weekly GC is space-reclaim only; skip model pulls and skip any operations
# that would block the background launchd job (like waiting for Ollama).
# GC script handles tool availability checks internally.
exec "$_repo_root/scripts/gc.sh"
