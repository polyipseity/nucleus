#!/usr/bin/env bash
# Daily sccache cache clearing service.
set -eu

# shellcheck disable=SC2034 # reason: reserved for future lib sourcing
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"

if ! command -v sccache >/dev/null 2>&1; then
  echo "sccache-gc: sccache not found in PATH; skipping"
  exit 1
fi

sccache --clear
