#!/usr/bin/env bash
# Idempotently symlinks the superpowers plugin into <nucleusUserRoot>/plugins/.
# Uses derive_nucleus_user_root() for platform-specific paths.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_ssp_src="$1"
_ssp_target="$(derive_nucleus_user_root)/plugins/superpowers"

if [ -L "$_ssp_target" ] && [ "$(readlink "$_ssp_target")" = "$_ssp_src" ]; then
  say -l superpowers "superpowers symlink already converged; skipping"
else
  mkdir -p "$(dirname "$_ssp_target")"
  ln -sfn "$_ssp_src" "$_ssp_target"
  say -l superpowers "superpowers symlinked to $_ssp_src"
fi
