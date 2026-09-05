#!/usr/bin/env bash
# Nautilus right-click script for stripping metadata from files.
# Passes all files directly to nucleus-utils strip-metadata, which handles
# unsupported formats with warnings.
set -eu

if [ $# -gt 0 ]; then
  exec nucleus-utils strip-metadata "$@"
fi
