#!/usr/bin/env bash
# Updates flake inputs, optionally updates macOS packages via Homebrew, and
# rewraps all SOPS-managed files for current recipients.
#
# Commands: [--flake|--no-flake] [--brew|--no-brew] [--sops|--no-sops].
# Each stage is independently skippable, so partial updates are possible
# (e.g. rewrap secrets without touching flake.lock).
#
# Environment variables read: NIX_CONFIG (merged into the update invocation),
# NUCLEUS_REPO_ROOT (via derive_repo_root).
#
# Prerequisites: nix with flakes; brew (macOS) and sops only when their
# stage is enabled. Exits 1 when a selected stage fails — flake errors are
# reported explicitly, and brew/sops failures abort via set -e.

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
. "$SCRIPT_DIR/../src/scripts/lib/lib.sh"

# usage
#   Prints the CLI synopsis and the three stage toggles to stdout.
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
  -h | --help)
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
  # WHY: --option warn-dirty false keeps dirty-repo warnings out of update
  # output; merge_nix_config preserves any user NIX_CONFIG additions.
  NIX_CONFIG="$(merge_nix_config)" NIX_PATH="nixpkgs=flake:nixpkgs" nix --option warn-dirty false "$@"
}

# update_flake_inputs
#   Runs `nix flake update` against the flake at src/. WHY: the flake lock
#   must live next to flake.nix (Nix requirement), so the update explicitly
#   targets src/ rather than the repo root.
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
  # WHY: these specific signatures are called out so an operator can retry
  # later instead of suspecting the lockfile itself broke.
  if printf '%s' "$flake_output" | grep -Eq 'API rate limit exceeded|unable to download|HTTP error 403'; then
    error "flake update failed due to transient fetch/rate-limit error"
  fi

  error "flake update failed"
}

# update_homebrew_if_available
#   Runs brew update, then upgrades formulae and casks. WHY: metadata is
#   refreshed first so upgrade decisions use current formula versions;
#   casks upgrade separately because their versioning differs from formulae.
update_homebrew_if_available() {

  # Refresh formula/cask metadata first to avoid stale-upgrade decisions.
  brew update
  # Upgrade all installed formulae and casks; mirrors winget --all behavior.
  brew upgrade
  brew upgrade --cask
}

# rewrap_sops_files
#   Re-encrypts every SOPS-managed repository asset with the recipient set
#   declared in .sops.yaml. WHY: after machine age/GPG keys are added or
#   removed, ciphertext is still bound to the old set — new machines could
#   not decrypt it. updatekeys rewraps in place without touching plaintext.
rewrap_sops_files() {
  # Rewrap every encrypted repository asset so recipients stay in sync with
  # .sops.yaml key declarations after machine additions/removals.
  sops_config="$REPO_ROOT/.sops.yaml"

  for encrypted_file in \
    "$REPO_ROOT"/src/secrets/users/*.yml; do
    if [ -f "$encrypted_file" ]; then
      sops --config "$sops_config" updatekeys --yes "$encrypted_file"
    fi
  done

  # WHY: overlay wallpapers are encrypted too (src/users/*/wallpapers/encrypted/*.sops)
  # and would otherwise rot against the updated recipient set.
  _update_wallpaper_list="$(mktemp)"
  find "$REPO_ROOT/src/users" -path '*/wallpapers/encrypted/*.sops' -type f >"$_update_wallpaper_list"
  while IFS= read -r encrypted_wallpaper; do
    if [ -f "$encrypted_wallpaper" ]; then
      sops --config "$sops_config" updatekeys --yes "$encrypted_wallpaper"
    fi
  done <"$_update_wallpaper_list"
  rm -f "$_update_wallpaper_list"
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

nuc_done "$@"
