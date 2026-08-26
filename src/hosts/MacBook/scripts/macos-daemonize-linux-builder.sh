#!/usr/bin/env bash
# Linux builder VM daemon — keeps the NixOS builder running via
# Apple Virtualization.framework.
# Work directory passed via LINUX_BUILDER_WORK_DIR env var or first positional arg.
# create-builder resolved from /nix/store at runtime (not runtimeInputs —
# avoids circular dependency: daemon wrapper → create-builder → NixOS VM →
# linux-builder → daemon).
# Usage: macos-daemonize-linux-builder.sh [work_dir]
set -euo pipefail

export TMPDIR=/run/org.nixos.linux-builder USE_TMPDIR=1
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"

work_dir="${LINUX_BUILDER_WORK_DIR:-${1:-/Library/Application Support/nucleus/linux-builder}}"
mkdir -p "$work_dir"
trap 'rm -rf '"$TMPDIR" EXIT

# Resolve create-builder from the Nix store at runtime.
# Cannot use runtimeInputs because that creates a build-time dependency chain:
#   daemon wrapper.drv → create-builder.drv → run-builder.drv → nixos-vm.drv
#   → nixos-system.drv → needs linux-builder → needs daemon → cycle.
# The bash glob finds whatever *-create-builder exists in /nix/store.
# The old output is kept alive by the previous generation's GC roots.
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
