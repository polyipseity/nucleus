#!/usr/bin/env bash
# Policy: tests must not reference real src/users/<username>/ identities — use test-user fixture only.

set -euo pipefail

FIXTURE_SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
FIXTURE_REPO_ROOT="$(CDPATH='' cd -- "$FIXTURE_SCRIPT_DIR/../fixtures/user-registry" && pwd)"
REAL_REPO_ROOT="$(CDPATH='' cd -- "$FIXTURE_SCRIPT_DIR/../.." && pwd)"
readonly FIXTURE_REPO_ROOT REAL_REPO_ROOT
FIXTURE_USERNAME=test-user
export FIXTURE_USERNAME
FIXTURE_REGISTRY_LOADER="$REAL_REPO_ROOT/src/scripts/lib/load-user-registry.sh"
readonly FIXTURE_REGISTRY_LOADER

run_fixture_registry_loader() {
  local host="$1"
  "$FIXTURE_REGISTRY_LOADER" --host "$host" --repo-root "$FIXTURE_REPO_ROOT"
}
