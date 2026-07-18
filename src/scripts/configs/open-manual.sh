#!/usr/bin/env bash
# Open nucleus manual via xdg-open.
# Used by Nautilus and Dolphin context menus.
set -eu

_nuc_repo='${NUCLEUS_REPO_ROOT:?NUCLEUS_REPO_ROOT not set}'
exec __XDG_OPEN_BIN__ "$_nuc_repo/src/hosts/NixOS/MANUAL.md"
