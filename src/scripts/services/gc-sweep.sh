#!/usr/bin/env bash
# Weekly garbage collection for Nix VM artifacts, build outputs, and caches.
# Also runs log rotate/expire (gc.sh step 9); daily log-gc-* jobs cover the
# same paths — overlap is intentional and idempotent.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

NUCLEUS_REPO_ROOT="${NUCLEUS_REPO_ROOT:?NUCLEUS_REPO_ROOT not set — set in launchd/service environment}"
if [ ! -f "$NUCLEUS_REPO_ROOT/scripts/gc.sh" ]; then
  die -l gc "scripts/gc.sh not found at $NUCLEUS_REPO_ROOT; skipping weekly GC"
fi

# Weekly GC is space-reclaim only; skip model pulls and skip any operations
# that would block the background launchd job (like waiting for Ollama).
# GC script handles tool availability checks internally.
exec "$NUCLEUS_REPO_ROOT/scripts/gc.sh"
