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

# Locate the nucleus repository root.  Resolution order:
#   1. ~/.config/nucleus/repo-root — written by apply.sh; reliable from
#      anywhere once apply has been run at least once.
#   2. git rev-parse --show-toplevel — works when CWD is inside the repo.
#      Stderr is suppressed because a non-repo CWD is expected and benign;
#      the exit code is checked via the conditional.
#   3. ~/dev/nucleus — canonical clone location declared in devRepos config.
resolve_nucleus_root() {
  _rnr_config_file="$HOME/.config/nucleus/repo-root"
  if [ -f "$_rnr_config_file" ]; then
    _rnr_root="$(cat "$_rnr_config_file")"
    if [ -n "$_rnr_root" ] && [ -d "$_rnr_root" ]; then
      printf '%s\n' "$_rnr_root"
      return 0
    fi
  fi
  # Stderr suppressed: git failure when CWD is not inside a repository is
  # expected and benign; the exit code is checked via the conditional.
  if _rnr_git_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    printf '%s\n' "$_rnr_git_root"
    return 0
  fi
  # Final fallback: canonical clone location declared in devRepos config.
  printf '%s\n' "$HOME/dev/nucleus"
}
REPO_ROOT="$(resolve_nucleus_root)"

min_free_gb="${NUCLEUS_MIN_FREE_GB:-10}"
skip_secret_health=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --min-free-gb)
      if [ "$#" -lt 2 ]; then
        printf '%s\n' "health: --min-free-gb requires a value" >&2
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
      printf '%s\n' "health: unsupported argument '$1'" >&2
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
    printf '%s\n' "health: insufficient disk space at repo filesystem (${available_kb:-0} KiB available, requires ${min_kb} KiB)." >&2
    return 1
  fi

  return 0
}

check_connectivity() {
  # Verifies network reachability to critical artifact/dependency endpoints.
  # This avoids launching expensive flows that are guaranteed to fail offline.
  if ! curl -fsSI --max-time 10 https://github.com >/dev/null; then
    printf '%s\n' "health: connectivity check failed for https://github.com" >&2
    return 1
  fi

  if ! curl -fsSI --max-time 10 https://cache.nixos.org >/dev/null; then
    printf '%s\n' "health: connectivity check failed for https://cache.nixos.org" >&2
    return 1
  fi

  return 0
}

check_secret_health() {
  # Ensures encryption identities currently available on the machine can decrypt
  # repository-managed secret files before activation depends on them.
  #
  # The machine age private key lives at /etc/sops/age/machine.txt (written by
  # deriveHostAgeKey in posix-sops.nix) and is the primary decryption identity
  # on provisioned machines.  sops does not search that path by default — it
  # only checks user-level standard locations — so SOPS_AGE_KEY_FILE must be
  # set explicitly.  On first bootstrap before deriveHostAgeKey has run, the
  # file is absent and sops falls back to the primary GPG key in the keyring,
  # which is imported via `gpg --import` as part of the bootstrap pre-requisite.
  _sch_machine_key="/etc/sops/age/machine.txt"
  if [ -f "$_sch_machine_key" ]; then
    SOPS_AGE_KEY_FILE="$_sch_machine_key"
    export SOPS_AGE_KEY_FILE
  fi

  for secret_file in "$REPO_ROOT/src/secrets/git-identities.yml" "$REPO_ROOT/src/secrets/gpg-personal.yml" "$REPO_ROOT/src/secrets/ssh-personal.yml"; do
    if [ ! -f "$secret_file" ]; then
      printf '%s\n' "health: expected secret file missing: $secret_file" >&2
      return 1
    fi

    if ! sops -d "$secret_file" >/dev/null; then
      printf '%s\n' "health: unable to decrypt secret file with current identities: $secret_file" >&2
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

printf '%s\n' "health: health checks passed"
