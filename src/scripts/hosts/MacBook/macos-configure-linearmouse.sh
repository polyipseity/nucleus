#!/usr/bin/env bash
# Create out-of-store symlinks for LinearMouse runtime config files pointing
# into the repository tree.  Resolves the overlay-selected config file at
# activation time so the link survives repo relocations and rebuilds.
set -euo pipefail

_ll_source="$1"

mkdir -p "$HOME/.config/linearmouse"
mkdir -p "$HOME/Library/Application Support/linearmouse"
ln -sf "$_ll_source" "$HOME/.config/linearmouse/linearmouse.json"
ln -sf "$_ll_source" "$HOME/Library/Application Support/linearmouse/linearmouse.json"
