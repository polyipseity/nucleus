#!/usr/bin/env bash
# Installs repository-local Git hooks for repos that opt into prek via
# prek.toml. mkApplyApp bundles pkgs.prek in runtimeInputs so first-run
# `nix run .#apply` can install hooks without host-global PATH state.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

# shellcheck source=lib/lib.sh
. "$SCRIPT_DIR/lib/lib.sh"

_ephi_repo_root=""
while [ "$#" -gt 0 ]; do
  case "$1" in
  --repo-root)
    _ephi_repo_root="$2"
    shift 2
    ;;
  *)
    usage_std "$(basename "$0")" "[--repo-root <path>]" "Install prek Git hooks for a repository"
    exit 2
    ;;
  esac
done

if [ -z "$_ephi_repo_root" ]; then
  _ephi_repo_root="$(derive_repo_root)"
fi
_ephi_config_path="$_ephi_repo_root/prek.toml"

if [ ! -f "$_ephi_config_path" ]; then
  exit 0
fi

if ! command -v prek >/dev/null 2>&1; then
  printf '%s\n' "prek: prek binary not found; skipping hook installation for $_ephi_repo_root" >&2
  exit 0
fi

if ! (cd "$_ephi_repo_root" && prek install --quiet); then
  printf '%s\n' "prek: failed to install hooks in $_ephi_repo_root" >&2
  exit 1
fi
