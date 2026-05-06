#!/usr/bin/env sh
# Checks pre-flight readiness before bootstrap/apply/update operations.
#
# Validates:
#   1. required free disk space at the repository root filesystem
#   2. outbound connectivity to key endpoints (GitHub + cache.nixos.org)
#   3. SOPS secret decryptability for repository-managed secret files
#
# Arguments:
#   --min-free-gb <int>  minimum free disk space in GiB (default: 10)
#   --skip-secret-health skip SOPS decryption identity verification
#
# Environment variables:
#   NUCLEUS_MIN_FREE_GB  alternate source for minimum free space threshold
#
# Exit conditions:
#   0 on success; non-zero if any check fails.

set -eu

# Use git to locate the repository root rather than navigating relative to $0.
# When this script runs as a Nix-built app (writeShellApplication), $0 resolves
# to a path inside the Nix store and $0-relative navigation would never reach
# the actual repository — the same pattern apply.sh already uses.
REPO_ROOT=$(git rev-parse --show-toplevel)

min_free_gb="${NUCLEUS_MIN_FREE_GB:-10}"
skip_secret_health=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --min-free-gb)
      if [ "$#" -lt 2 ]; then
        printf '%s\n' "nucleus: --min-free-gb requires a value" >&2
        exit 1
      fi
      min_free_gb="$2"
      shift 2
      ;;
    --skip-secret-health)
      skip_secret_health=true
      shift
      ;;
    *)
      printf '%s\n' "nucleus: unsupported argument '$1'" >&2
      exit 1
      ;;
  esac
done

check_disk_space() {
  # Fails fast when free disk is below threshold to avoid half-finished
  # rebuilds, package downloads, or decrypt/write operations on low storage.
  min_kb=$((min_free_gb * 1024 * 1024))
  available_kb=$(df -Pk "$REPO_ROOT" | awk 'NR == 2 { print $4 }')

  if [ -z "$available_kb" ] || [ "$available_kb" -lt "$min_kb" ]; then
    printf '%s\n' "nucleus: insufficient disk space at repo filesystem (${available_kb:-0} KiB available, requires ${min_kb} KiB)." >&2
    return 1
  fi

  return 0
}

check_connectivity() {
  # Verifies network reachability to critical artifact/dependency endpoints.
  # This avoids launching expensive flows that are guaranteed to fail offline.
  if ! curl -fsSI --max-time 10 https://github.com >/dev/null; then
    printf '%s\n' "nucleus: connectivity check failed for https://github.com" >&2
    return 1
  fi

  if ! curl -fsSI --max-time 10 https://cache.nixos.org >/dev/null; then
    printf '%s\n' "nucleus: connectivity check failed for https://cache.nixos.org" >&2
    return 1
  fi

  return 0
}

check_secret_health() {
  # Ensures encryption identities currently available on the machine can decrypt
  # repository-managed secret files before activation depends on them.
  for secret_file in "$REPO_ROOT/src/secrets/git-identities.yml" "$REPO_ROOT/src/secrets/gpg-personal.yml" "$REPO_ROOT/src/secrets/ssh-personal.yml"; do
    if [ ! -f "$secret_file" ]; then
      printf '%s\n' "nucleus: expected secret file missing: $secret_file" >&2
      return 1
    fi

    if ! sops -d "$secret_file" >/dev/null; then
      printf '%s\n' "nucleus: unable to decrypt secret file with current identities: $secret_file" >&2
      return 1
    fi
  done

  return 0
}

check_disk_space
check_connectivity
if [ "$skip_secret_health" = false ]; then
  check_secret_health
fi

printf '%s\n' "nucleus: health checks passed"
