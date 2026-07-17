#!/usr/bin/env bash
# Updates flake inputs, optionally updates macOS packages via Homebrew, and
# rewraps all SOPS-managed files for current recipients.

set -euo pipefail

# Resolve symlinks so SCRIPT_DIR works from Nix wrapper symlinks.
_self="$0"
if [ -h "$_self" ]; then
  _target="$(readlink "$_self")"
  case "$_target" in
    /*) _self="$_target" ;;
    *) _self="$(dirname "$_self")/$_target" ;;
  esac
fi
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$_self")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../src/scripts/lib/lib.sh"

usage() {
  usage_std "$(basename "$0")" "[options]"
  cat <<'EOF'
  --flake|--no-flake    Control nix flake update (default: --flake).
  --brew|--no-brew      Control Homebrew update/upgrade (macOS only) (default: --brew).
  --sops|--no-sops      Control sops updatekeys (default: --sops).
EOF
}

REPO_ROOT="$(derive_repo_root)"

flake=true
brew=true
sops=true

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --flake)
      flake=true
      ;;
    --no-flake)
      flake=false
      ;;
    --brew)
      brew=true
      ;;
    --no-brew)
      brew=false
      ;;

    --sops)
      sops=true
      ;;
    --no-sops)
      sops=false
      ;;

    *)
      error "unsupported argument '$1'"
      usage >&2
      exit 1
      ;;
  esac
  shift
done

run_nix() {
  # NIX_PATH is set explicitly because darwin-rebuild's export NIX_PATH=${NIX_PATH:-}
  # would otherwise clear it, overriding the nix-path config option.
  NIX_CONFIG="$(merge_nix_config)" NIX_PATH="nixpkgs=flake:nixpkgs" nix --option warn-dirty false "$@"
}

update_flake_inputs() {
  # Updates pinned upstream revisions in src/flake.lock.
  if flake_output="$(run_nix flake update --flake "$REPO_ROOT/src" 2>&1)"; then
    if [ -n "$flake_output" ]; then
      printf '%s\n' "$flake_output"
    fi
    return 0
  fi

  printf '%s\n' "$flake_output" >&2

  # Transient network / GitHub API-rate-limit failures should propagate as
  # errors so callers can handle the failure upstream.
  if printf '%s' "$flake_output" | grep -Eq 'API rate limit exceeded|unable to download|HTTP error 403'; then
    error "flake update failed due to transient fetch/rate-limit error"
  fi

  error "flake update failed"
}

update_homebrew_if_available() {

  # Refresh formula/cask metadata first to avoid stale-upgrade decisions.
  brew update
  # Upgrade all installed formulae and casks; mirrors winget --all behavior.
  brew upgrade
  brew upgrade --cask
}

rewrap_sops_files() {
  # Rewrap every encrypted repository asset so recipients stay in sync with
  # .sops.yaml key declarations after machine additions/removals.
  sops_config="$REPO_ROOT/.sops.yaml"

  for user_secret_file in "$REPO_ROOT"/src/secrets/users-*.yml; do
    if [ -f "$user_secret_file" ]; then
      sops --config "$sops_config" updatekeys --yes "$user_secret_file"
    fi
  done

  for encrypted_file in \
    "$REPO_ROOT/src/secrets/git-identities.yml" \
    "$REPO_ROOT/src/secrets/gpg-personal.yml" \
    "$REPO_ROOT/src/secrets/ssh-personal.yml"; do
    sops --config "$sops_config" updatekeys --yes "$encrypted_file"
  done

  wallpaper_dir="$REPO_ROOT/src/assets/wallpapers"
  if [ -d "$wallpaper_dir" ]; then
    for encrypted_wallpaper in "$wallpaper_dir"/*.sops; do
      if [ -f "$encrypted_wallpaper" ]; then
        sops --config "$sops_config" updatekeys --yes "$encrypted_wallpaper"
      fi
    done
  fi
}

if [ "$flake" = true ]; then
  update_flake_inputs
fi

if [ "$brew" = true ]; then
  update_homebrew_if_available
fi

if [ "$sops" = true ]; then
  rewrap_sops_files
fi

nuc_done
