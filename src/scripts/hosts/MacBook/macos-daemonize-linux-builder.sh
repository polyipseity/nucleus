#!/usr/bin/env bash
# Linux builder VM daemon — keeps the NixOS builder running via
# Apple Virtualization.framework.
# Variables below are substituted via Nix replaceStrings at build time.
export TMPDIR=/run/org.nixos.linux-builder USE_TMPDIR=1
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"
mkdir -p "__WORK_DIR__"
trap 'rm -rf '"$TMPDIR" EXIT
exec __CREATE_BUILDER_BIN__
