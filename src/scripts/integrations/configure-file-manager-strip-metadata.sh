#!/usr/bin/env bash
# Nautilus right-click script for stripping metadata from files.
# Passes all files directly to nucleus-utils strip-metadata, which reports every
# input it could not process (unsupported formats) in a modal popup.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=../lib/bash-guard.sh
. "$SCRIPT_DIR/../lib/bash-guard.sh"
bash_guard_require 5 1 configure-file-manager-strip-metadata

if [ $# -gt 0 ]; then
  # WHY: --dialog: Nautilus Scripts cannot declare per-file-type filtering, so
  # this entry is offered for every selection; the modal popup is the only
  # feedback the user gets about a file that was skipped.
  exec nucleus-utils strip-metadata --dialog "$@"
fi
