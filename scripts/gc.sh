#!/usr/bin/env sh
# Performs bounded garbage collection on POSIX hosts.
#
# Operations:
#   1. run nix store garbage collection (if nix is available)
#   2. remove stale decrypted wallpaper files under ~/Pictures/wallpapers
#
# Arguments:
#   --skip-nix-gc          skip nix-collect-garbage
#   --skip-wallpaper-prune skip stale wallpaper cleanup
#
# Environment variables:
#   (none)
#
# Exit conditions:
#   0 on success; non-zero on failure.

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)

skip_nix_gc=false
skip_wallpaper_prune=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-nix-gc)
      skip_nix_gc=true
      ;;
    --skip-wallpaper-prune)
      skip_wallpaper_prune=true
      ;;
    *)
      printf '%s\n' "nucleus: unsupported argument '$1'" >&2
      exit 1
      ;;
  esac
  shift
done

run_nix_gc_if_available() {
  # Store cleanup is best-effort because this helper also runs on hosts where
  # Nix may not be installed (for example minimal CI images).
  if ! command -v nix-collect-garbage >/dev/null 2>&1; then
    printf '%s\n' "nucleus: nix-collect-garbage unavailable; skipping Nix GC"
    return 0
  fi

  nix-collect-garbage --delete-older-than 30d
}

prune_stale_wallpapers() {
  # Keep the decrypted wallpaper output directory in sync with declarative
  # sources so stale files do not accumulate across apply cycles.
  assets_dir="$REPO_ROOT/src/assets/wallpapers"
  output_dir="$HOME/Pictures/wallpapers"

  if [ ! -d "$assets_dir" ] || [ ! -d "$output_dir" ]; then
    return 0
  fi

  managed_names_tmp=$(mktemp)
  trap 'rm -f "$managed_names_tmp"' EXIT INT TERM

  for asset in "$assets_dir"/*.sops; do
    if [ -f "$asset" ]; then
      basename "$asset" .sops >>"$managed_names_tmp"
    fi
  done

  for candidate in "$output_dir"/*; do
    if [ ! -f "$candidate" ]; then
      continue
    fi

    candidate_name=$(basename "$candidate")
    case "$candidate_name" in
      *.xml)
        continue
        ;;
    esac

    candidate_base=${candidate_name%.*}
    if ! grep -Fxq "$candidate_base" "$managed_names_tmp"; then
      rm -f "$candidate"
    fi
  done
}

if [ "$skip_nix_gc" = false ]; then
  run_nix_gc_if_available
fi

if [ "$skip_wallpaper_prune" = false ]; then
  prune_stale_wallpapers
fi

printf '%s\n' "nucleus: gc workflow completed"
