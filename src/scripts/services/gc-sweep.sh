# Weekly garbage collection for Nix VM artifacts, build outputs, and caches.
set -eu

# __REPO_ROOT__ is substituted at build time by Nix.  Hard-fail if the
# token was not substituted (checking at runtime catches build-time env
# gaps and prevents silent fallback to stale paths).
_repo_root="__REPO_ROOT__"
if [ -z "$_repo_root" ] || [ ! -d "$_repo_root" ]; then
  echo "gc: __REPO_ROOT__ is empty or not a directory — set NUCLEUS_REPO_ROOT at build time" >&2
  exit 1
fi

if [ ! -f "$_repo_root/scripts/gc.sh" ]; then
  echo "gc: scripts/gc.sh not found at $_repo_root; skipping weekly GC"
  exit 1
fi

# Weekly GC is space-reclaim only; skip model pulls and skip any operations
# that would block the background launchd job (like waiting for Ollama).
# GC script handles tool availability checks internally.
exec "$_repo_root/scripts/gc.sh"
