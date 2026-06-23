#!/usr/bin/env bash
# Validates free disk space, outbound connectivity to key endpoints (GitHub,
# cache.nixos.org), and SOPS secret decryptability for repository-managed
# secret files.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../src/scripts/lib.sh"

usage() {
  usage_std "health-check.sh" "[options]" "Checks pre-flight readiness before bootstrap/apply/update operations."
}

REPO_ROOT="$(resolve_nucleus_root)"

min_free_bytes=10000000000
secret_health=true
log_health=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --min-free-bytes)
      if [ "$#" -lt 2 ]; then
        printf '%s\n' "health: --min-free-bytes requires a value" >&2
        usage >&2
        exit 1
      fi
      min_free_bytes="$2"
      shift
      ;;
    --secret-health)
      secret_health=true
      ;;
    --no-secret-health)
      secret_health=false
      ;;
    --log-health)
      log_health=true
      require_command jq
      ;;
    *)
      printf '%s\n' "health: unsupported argument '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

check_disk_space() {
  # Fails fast when free disk is below threshold to avoid half-finished
  # rebuilds, package downloads, or decrypt/write operations on low storage.
  min_kb=$((min_free_bytes / 1024))
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

  for secret_file in "$REPO_ROOT"/src/secrets/users-*.yml; do
    if [ -f "$secret_file" ] && ! sops -d "$secret_file" >/dev/null; then
      printf '%s\n' "health: unable to decrypt secret file with current identities: $secret_file" >&2
      return 1
    fi
  done

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

check_log_health() {
  # Verify log directories exist, check file sizes against rotation
  # thresholds, and validate that sanitized logs contain no control chars.
  log_dir="$(nucleus_log_dir)"
  system_log_dir="$(nucleus_system_log_dir)"
  services_json="$REPO_ROOT/src/modules/services.json"
  failures=0

  for dir in "$log_dir" "$system_log_dir"; do
    if [ -d "$dir" ]; then
      if [ ! -w "$dir" ]; then
        printf '%s\n' "health: log dir '$dir' is not writable" >&2
        failures=$((failures + 1))
      fi
    else
      printf '%s\n' "health: log dir '$dir' does not exist" >&2
      failures=$((failures + 1))
    fi
  done

  while IFS= read -r svc; do
    capture=$(jq -r --arg svc "$svc" '.[$svc].logging.capture // "all"' "$services_json")
    max_size=$(jq -r --arg svc "$svc" '.[$svc].logging.maxSize // 10485760' "$services_json")
    sanitize=$(jq -r --arg svc "$svc" '.[$svc].logging.sanitize // true' "$services_json")

    if [ "$capture" = "none" ]; then
      continue
    fi

    for dir in "$log_dir" "$system_log_dir"; do
      for log_file in "$dir/$svc"/*.log; do
        [ -f "$log_file" ] || continue

        # Check file size against rotation threshold
        size=$(wc -c < "$log_file")
        threshold=$((max_size * 80 / 100))
        if [ "$size" -gt "$threshold" ]; then
          printf '%s\n' "health: warning — '$log_file' ($size bytes) exceeds 80% of rotation max ($max_size bytes)" >&2
        fi

        # Spot-check for control characters when sanitize is enabled
        if [ "$sanitize" = "true" ] && head -n 5 "$log_file" | tr -d '[:print:][:space:]' | grep -q .; then
          printf '%s\n' "health: warning — '$log_file' contains control characters despite sanitize=true" >&2
          failures=$((failures + 1))
        fi
      done
    done
  done <<< "$(jq -r 'to_entries[] | select(.key | startswith("$") | not) | .key' "$services_json" | sort)"

  if [ "$failures" -gt 0 ]; then
    printf '%s\n' "health: log health checks failed ($failures issue(s))" >&2
    return 1
  fi
  return 0
}
check_disk_space
check_connectivity
if [ "$secret_health" = true ]; then
  check_secret_health
fi
if [ "$log_health" = true ]; then
  check_log_health
fi

printf '%s\n' "health: health checks passed"
