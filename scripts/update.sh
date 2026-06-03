#!/usr/bin/env sh
# Orchestrates repository-wide update tasks in one deterministic sequence.
#
# Operations:
#   1. update flake inputs (src/flake.lock)
#   2. optionally update macOS packages via Homebrew (when available)
#   3. optionally update Windows packages via winget (when available)
#   4. rewrap all SOPS-managed files for current recipients
#
# Arguments:
#   --without-flake       do not run nix flake update
#   --without-brew        do not run Homebrew update/upgrade (macOS only)
#   --without-winget      do not run winget upgrade (Windows only)
#   --without-sops        do not run sops updatekeys
#
# Environment variables:
#   NIX_CONFIG  merged with required flake feature flags for nix commands
#
# Exit conditions:
#   0 on success; non-zero on first failed step.

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$SCRIPT_DIR/../src/scripts/lib.sh"

usage() {
  cat <<'EOF'
usage: update.sh [options]

  --without-flake    Do not run nix flake update.
  --without-brew     Do not run Homebrew update/upgrade (macOS only).
  --without-winget   Do not run winget upgrade (Windows only).
  --without-sops     Do not run sops updatekeys.
EOF
}

REPO_ROOT="$(resolve_nucleus_root)"

do_flake=true
do_brew=true
do_winget=true
do_sops=true

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --without-flake)
      do_flake=false
      ;;
    --without-brew)
      do_brew=false
      ;;
    --without-winget)
      do_winget=false
      ;;
    --without-sops)
      do_sops=false
      ;;
    *)
      printf '%s\n' "update: unsupported argument '$1'" >&2
      usage >&2
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
  NIX_CONFIG="$(merge_nix_config)" nix --option warn-dirty false "$@"
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

  # Transient network / GitHub API-rate-limit failures should not abort the
  # whole update workflow: continue with host package updates and SOPS rewrap.
  if printf '%s' "$flake_output" | grep -Eq 'API rate limit exceeded|unable to download|HTTP error 403'; then
    printf '%s\n' "update: warning: flake update skipped due to transient fetch/rate-limit error" >&2
    return 0
  fi

  printf '%s\n' "update: error: flake update failed" >&2
  return 1
}

update_homebrew_if_available() {
  # Homebrew upgrades are executed only when brew is present, allowing this
  # script to stay portable across non-macOS hosts.
  if ! command -v brew >/dev/null 2>&1; then
    printf '%s\n' "update: brew unavailable on this host, skipping Homebrew upgrade step"
    return 0
  fi

  # Refresh formula/cask metadata first to avoid stale-upgrade decisions.
  brew update
  # Upgrade all installed formulae and casks; mirrors winget --all behavior.
  brew upgrade
  brew upgrade --cask
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

if [ "$do_flake" = true ]; then
  update_flake_inputs
fi

if [ "$do_brew" = true ]; then
  update_homebrew_if_available
fi

if [ "$do_winget" = true ]; then
  update_windows_packages_if_available
fi

if [ "$do_sops" = true ]; then
  rewrap_sops_files
fi

printf '%s\n' "update: update workflow completed"
