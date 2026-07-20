# Weekly garbage collection for Nix VM artifacts, build outputs, and caches.
set -eu

# require_repo_root() is provided via repo-root-lib.sh (prepended at build time).
require_repo_root gc

# shellcheck disable=SC2154 # _repo_root is set by require_repo_root above.
if [ ! -f "$_repo_root/scripts/gc.sh" ]; then
  echo "gc: scripts/gc.sh not found at $_repo_root; skipping weekly GC"
  exit 1
fi

# Weekly GC is space-reclaim only; skip model pulls and skip any operations
# that would block the background launchd job (like waiting for Ollama).
# GC script handles tool availability checks internally.
exec "$_repo_root/scripts/gc.sh"
