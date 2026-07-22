#!/usr/bin/env bash
# Daily sccache cache clearing service.
set -eu

if ! command -v sccache >/dev/null 2>&1; then
  echo "sccache-gc: sccache not found in PATH; skipping"
  exit 1
fi

sccache --clear
