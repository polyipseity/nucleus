#!/usr/bin/env bash
# Live-repo entry point for nucleus apply. Delegates to src/scripts/apply.sh so
# git pull can take effect before the store-bundled nucleus-apply is rebuilt.
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=../src/scripts/lib/bash-guard.sh
. "$SCRIPT_DIR/../src/scripts/lib/bash-guard.sh"
bash_guard_require 5 1 apply

exec "$SCRIPT_DIR/../src/scripts/apply.sh" "$@"
