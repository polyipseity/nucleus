#!/usr/bin/env bash
# Daily sccache cache clearing service.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/bash-guard.sh
. "$SCRIPT_DIR/../lib/bash-guard.sh"
bash_guard_require 5 1 sccache-gc
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

clear_sccache_cache
