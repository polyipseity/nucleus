#!/usr/bin/env bash
set -eu
_nuc_repo="${NUCLEUS_REPO_ROOT:?NUCLEUS_REPO_ROOT not set}"
exec xdg-open "$_nuc_repo/src/hosts/NixOS/MANUAL.md"
