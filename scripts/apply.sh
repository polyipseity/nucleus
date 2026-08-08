#!/usr/bin/env bash
# Live-repo entry point for nucleus apply. Delegates to src/scripts/apply.sh so
# git pull can take effect before the store-bundled nucleus-apply is rebuilt.
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
exec "$SCRIPT_DIR/../src/scripts/apply.sh" "$@"
