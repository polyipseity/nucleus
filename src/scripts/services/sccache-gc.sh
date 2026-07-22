#!/usr/bin/env bash
# Daily sccache cache clearing service.
set -eu

# require_repo_root() is provided via repo-root-lib.sh (prepended at build time).
require_repo_root sccache-gc

if ! command -v sccache >/dev/null 2>&1; then
  echo "sccache-gc: sccache not found in PATH; skipping"
  exit 1
fi

sccache --clear
