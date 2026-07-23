#!/usr/bin/env bash
# Linux builder VM daemon — keeps the NixOS builder running via
# Apple Virtualization.framework.
# Work directory passed via LINUX_BUILDER_WORK_DIR env var or first positional arg.
# create-builder resolved from PATH.
# Usage: macos-daemonize-linux-builder.sh [work_dir]
set -euo pipefail

export TMPDIR=/run/org.nixos.linux-builder USE_TMPDIR=1
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"

work_dir="${LINUX_BUILDER_WORK_DIR:-${1:-/var/lib/linux-builder}}"
mkdir -p "$work_dir"
trap 'rm -rf '"$TMPDIR" EXIT
exec create-builder
