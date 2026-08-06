#!/usr/bin/env bash
# Validates free disk space, outbound connectivity to key endpoints (GitHub,
# cache.nixos.org), and SOPS secret decryptability for repository-managed
# secret files.
#
# Commands: [--min-free-bytes N] [--secret-health|--no-secret-health]
# [--log-health]. Disk and connectivity checks always run; --log-health is
# opt-in because it reads the services.json registries.
#
# Environment variables read: SOPS_AGE_KEY_FILE (exported when the machine
# age key exists so sops finds it), NUCLEUS_REPO_ROOT (via derive_repo_root),
# NUCLEUS_LOG_DIR / NUCLEUS_SYSTEM_LOG_DIR (via lib.sh).
#
# Prerequisites: curl, sops, and (for --log-health) jq. Exits 1 when a check
# fails — log checks are aggregated first — and exits 0 when all pass.

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
#   Prints the CLI synopsis and available check flags to stdout.
usage() {
  usage_std "health-check.sh" "[options]" "Checks pre-flight readiness before bootstrap/apply/update operations."
}

REPO_ROOT="$(derive_repo_root)"

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
        error "--min-free-bytes requires a value"
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
      error "unsupported argument '$1'"
      usage >&2
      exit 1
      ;;
  esac
  shift
done

# check_disk_space
#   Fails when the repo filesystem has less free space than the threshold.
#   WHY: df -Pk is POSIX-portable (no GNU df required on macOS); awk picks
#   the free column without locale-dependent formatting.
check_disk_space() {
  # Fails fast when free disk is below threshold to avoid half-finished
  # rebuilds, package downloads, or decrypt/write operations on low storage.
  min_kb=$((min_free_bytes / 1024))
  available_kb=$(df -Pk "$REPO_ROOT" | awk 'NR == 2 { print $4 }')

  if [ -z "$available_kb" ] || [ "$available_kb" -lt "$min_kb" ]; then
    error "insufficient disk space at repo filesystem (${available_kb:-0} KiB available, requires ${min_kb} KiB)."
  fi

  return 0
}

# check_connectivity
#   Verifies reachability of GitHub and cache.nixos.org. WHY: these two
#   endpoints cover the flake fetch path and the binary-substitution path;
#   the --max-time 10 cap keeps a stalled network from hanging the check.
check_connectivity() {
  # Verifies network reachability to critical artifact/dependency endpoints.
  # This avoids launching expensive flows that are guaranteed to fail offline.
  if ! curl -fsSI --max-time 10 https://github.com >/dev/null; then
    error "connectivity check failed for https://github.com"
  fi

  if ! curl -fsSI --max-time 10 https://cache.nixos.org >/dev/null; then
    error "connectivity check failed for https://cache.nixos.org"
  fi

  return 0
}

# check_secret_health
#   Decrypt-checks every SOPS-managed secret file. WHY: activation depends on
#   these secrets (git identities, SSH keys); verifying decryptability here
#   catches identity rot before a half-finished activation.
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

  for secret_file in "$REPO_ROOT"/src/secrets/users/*.yml; do
    if [ -f "$secret_file" ] && ! sops -d "$secret_file" >/dev/null; then
      error "unable to decrypt secret file with current identities: $secret_file"
    fi
  done

  for secret_file in "$REPO_ROOT/src/secrets/gpg-personal.yml" "$REPO_ROOT/src/secrets/ssh-personal.yml"; do
    if [ ! -f "$secret_file" ]; then
      error "expected secret file missing: $secret_file"
    fi

    if ! sops -d "$secret_file" >/dev/null; then
      error "unable to decrypt secret file with current identities: $secret_file"
    fi
  done

  return 0
}

# check_log_health
#   Validates log dirs and per-service log files against the rotation and
#   sanitize policy in services.json.
check_log_health() {
  # Verify log directories exist, check file sizes against rotation
  # thresholds, and validate that sanitized logs contain no control chars.
  log_dir="$(nucleus_log_dir)"
  system_log_dir="$(nucleus_system_log_dir)"
  services_json="$REPO_ROOT/src/modules/services.json"
  services_schema_json="$REPO_ROOT/src/modules/services.schema.json"
  _max_size_default=$(jq -r '.definitions.loggingEntry.properties.maxSize.default // 10000000' "$services_schema_json")
  failures=0

  for dir in "$log_dir" "$system_log_dir"; do
    if [ -d "$dir" ]; then
      if [ ! -w "$dir" ]; then
        warn "log dir '$dir' is not writable"
        failures=$((failures + 1))
      fi
    else
      warn "log dir '$dir' does not exist"
      failures=$((failures + 1))
    fi
  done

  while IFS= read -r svc; do
    capture=$(jq -r --arg svc "$svc" '.[$svc].logging.capture // "all"' "$services_json")
    max_size=$(jq -r --arg svc "$svc" --arg def "$_max_size_default" '(.[$svc].logging.maxSize // ($def | tonumber))' "$services_json") # bytes
    sanitize=$(jq -r --arg svc "$svc" '.[$svc].logging.sanitize // true' "$services_json")

    if [ "$capture" = "none" ]; then
      continue
    fi

    while IFS= read -r subdir; do
      [ -n "$subdir" ] || continue
      for log_file in "$log_dir/$subdir"/*.log; do
        [ -f "$log_file" ] || continue

        # Check file size against rotation threshold
        # WHY: 80% is the warning mark — services rotate at maxSize, so
        # operator action is needed before the next rotation window.
        size=$(wc -c < "$log_file")
        threshold=$((max_size * 80 / 100))
        if [ "$size" -gt "$threshold" ]; then
          warn "'$log_file' ($size bytes) exceeds 80% of rotation max ($max_size bytes)"
        fi

        # Spot-check for control characters when sanitize is enabled
        if [ "$sanitize" = "true" ] && head -n 5 "$log_file" | tr -d '[:print:][:space:]' | grep -q .; then
          warn "'$log_file' contains control characters despite sanitize=true"
          failures=$((failures + 1))
        fi
      done
    done <<< "$(jq -r --arg svc "$svc" '.[$svc].logging.dirs.user[]? // empty' "$services_json")"

    while IFS= read -r subdir; do
      [ -n "$subdir" ] || continue
      for log_file in "$system_log_dir/$subdir"/*.log; do
        [ -f "$log_file" ] || continue

        size=$(wc -c < "$log_file")
        threshold=$((max_size * 80 / 100))
        if [ "$size" -gt "$threshold" ]; then
          warn "'$log_file' ($size bytes) exceeds 80% of rotation max ($max_size bytes)"
        fi

        if [ "$sanitize" = "true" ] && head -n 5 "$log_file" | tr -d '[:print:][:space:]' | grep -q .; then
          warn "'$log_file' contains control characters despite sanitize=true"
          failures=$((failures + 1))
        fi
      done
    done <<< "$(jq -r --arg svc "$svc" '.[$svc].logging.dirs.system[]? // empty' "$services_json")"
  # WHY: JSON meta keys ($schema, $comment) are excluded from the service
  # enumeration so they are not treated as services.
  done <<< "$(jq -r 'to_entries[] | select(.key | startswith("$") | not) | .key' "$services_json" | sort)"

  if [ "$failures" -gt 0 ]; then
    error "log health checks failed ($failures issue(s))"
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

nuc_done
