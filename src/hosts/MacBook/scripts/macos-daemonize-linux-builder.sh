#!/usr/bin/env bash
# Keep the NixOS builder VM running under Apple Virtualization.framework.
#
# WHY resolve create-builder from /nix/store at runtime rather than
# runtimeInputs: the daemon wrapper → create-builder → NixOS VM → linux-builder
# → daemon chain would otherwise cycle. The glob takes whatever
# *-create-builder exists; the previous output stays alive via its own GC roots.
set -euo pipefail

export TMPDIR=/run/org.nixos.linux-builder USE_TMPDIR=1
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"

work_dir="${LINUX_BUILDER_WORK_DIR:-${1:-/Library/Application Support/nucleus/linux-builder}}"
mkdir -p "$work_dir"
trap 'rm -rf '"$TMPDIR" EXIT

create_builder=""
for _d in /nix/store/*-create-builder; do
  if [ -x "$_d/bin/create-builder" ]; then
    create_builder="$_d/bin/create-builder"
    break
  fi
done
if [ -z "$create_builder" ]; then
  echo "FATAL: create-builder not found in /nix/store" >&2
  exit 1
fi
exec "$create_builder"
