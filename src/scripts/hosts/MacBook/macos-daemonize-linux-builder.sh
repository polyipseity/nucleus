#!/usr/bin/env bash
# Linux builder VM daemon — keeps the NixOS builder running via
# Apple Virtualization.framework.
# Work directory passed as first positional arg.  create-binary resolved from PATH.
# Usage: macos-daemonize-linux-builder.sh [work_dir]
set -euo pipefail

export TMPDIR=/run/org.nixos.linux-builder USE_TMPDIR=1
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"

work_dir="${1:-/var/lib/linux-builder}"
mkdir -p "$work_dir"
trap 'rm -rf '"$TMPDIR" EXIT
exec create-builder
