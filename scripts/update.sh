#!/usr/bin/env sh
# Orchestrates repository-wide update tasks in one deterministic sequence.
#
# Operations:
#   1. update flake inputs (src/flake.lock)
#   2. optionally update Windows packages via winget (when available)
#   3. rewrap all SOPS-managed files for current recipients
#
# Arguments:
#   --skip-flake       do not run nix flake update
#   --skip-winget      do not run winget upgrade (Windows only)
#   --skip-sops        do not run sops updatekeys
#
# Environment variables:
#   NIX_CONFIG  merged with required flake feature flags for nix commands
#
# Exit conditions:
#   0 on success; non-zero on first failed step.

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)

skip_flake=false
skip_winget=false
skip_sops=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-flake)
      skip_flake=true
      ;;
    --skip-winget)
      skip_winget=true
      ;;
    --skip-sops)
      skip_sops=true
      ;;
    *)
      printf '%s\n' "update: unsupported argument '$1'" >&2
      exit 1
      ;;
  esac
  shift
done

merge_nix_config() {
  # Keep flake feature flags centralized so every nix call in this script works
  # on hosts where those features are not globally enabled yet.
  if [ -n "${NIX_CONFIG:-}" ]; then
    printf '%s\n%s' "$NIX_CONFIG" "experimental-features = nix-command flakes"
  else
    printf '%s' "experimental-features = nix-command flakes"
  fi
}

run_nix() {
  NIX_CONFIG="$(merge_nix_config)" nix "$@"
}

update_flake_inputs() {
  # Updates pinned upstream revisions in src/flake.lock.
  run_nix flake update --flake "$REPO_ROOT/src"
}

update_windows_packages_if_available() {
  # Winget upgrades are executed only when winget is present, allowing this
  # script to stay portable across POSIX and Windows hosts.
  if ! command -v winget >/dev/null 2>&1; then
    printf '%s\n' "update: winget unavailable on this host, skipping Windows package upgrade step"
    return 0
  fi

  winget upgrade --all --accept-package-agreements --accept-source-agreements --disable-interactivity
}

rewrap_sops_files() {
  # Rewrap every encrypted repository asset so recipients stay in sync with
  # .sops.yaml key declarations after machine additions/removals.
  for encrypted_file in \
    "$REPO_ROOT/src/secrets/git-identities.yml" \
    "$REPO_ROOT/src/secrets/gpg-personal.yml" \
    "$REPO_ROOT/src/secrets/ssh-personal.yml"; do
    sops updatekeys --yes "$encrypted_file"
  done

  wallpaper_dir="$REPO_ROOT/src/assets/wallpapers"
  if [ -d "$wallpaper_dir" ]; then
    for encrypted_wallpaper in "$wallpaper_dir"/*.sops; do
      if [ -f "$encrypted_wallpaper" ]; then
        sops updatekeys --yes "$encrypted_wallpaper"
      fi
    done
  fi
}

if [ "$skip_flake" = false ]; then
  update_flake_inputs
fi

if [ "$skip_winget" = false ]; then
  update_windows_packages_if_available
fi

if [ "$skip_sops" = false ]; then
  rewrap_sops_files
fi

printf '%s\n' "update: update workflow completed"
