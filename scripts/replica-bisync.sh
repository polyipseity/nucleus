#!/usr/bin/env sh
# Synchronize enabled cloud replicas declared in src/modules/users.json.
#
# For each enabled replica of the current user:
#   - direction=pull         => rclone sync remote -> local
#   - direction=push         => rclone sync local  -> remote
#   - direction=bidirectional => rclone bisync local <-> remote
#
# Intended usage:
#   - Post-apply best-effort convergence from src/scripts/apply.sh
#   - Manual invocation via `nucleus-replica-bisync`

set -eu

# Locate the nucleus repository root. Resolution order:
#   1. ~/.config/nucleus/repo-root — written by apply.sh; reliable from
#      anywhere once apply has been run at least once.
#   2. git rev-parse --show-toplevel — works when CWD is inside the repo.
#      Stderr is suppressed because non-repo CWD is expected and benign.
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
  if _rnr_git_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    if [ -n "$_rnr_git_root" ] && [ -d "$_rnr_git_root" ]; then
      printf '%s\n' "$_rnr_git_root"
      return 0
    fi
  fi
  printf '%s\n' "$HOME/dev/nucleus"
}

REPO_ROOT="$(resolve_nucleus_root)"
USERS_JSON="$REPO_ROOT/src/modules/users.json"

usage() {
  cat <<'EOF'
usage: replica-bisync.sh [--dry-run] [--replica-id ID]

  --dry-run         Print planned rclone commands without executing them.
  --replica-id ID   Restrict execution to a single replica id.
EOF
}

dry_run=false
replica_id_filter=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      dry_run=true
      ;;
    --replica-id)
      shift
      if [ "$#" -eq 0 ] || [ -z "$1" ]; then
        printf '%s\n' "replica-bisync: --replica-id requires a value" >&2
        exit 1
      fi
      replica_id_filter="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf '%s\n' "replica-bisync: unsupported argument '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [ ! -f "$USERS_JSON" ]; then
  printf '%s\n' "replica-bisync: users registry not found at $USERS_JSON" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' "replica-bisync: jq not found; cannot parse users.json" >&2
  exit 1
fi

if ! command -v rclone >/dev/null 2>&1; then
  printf '%s\n' "replica-bisync: rclone not found; skipping replica sync"
  exit 0
fi

# Export config passphrase when available so encrypted rclone.conf works
# in non-interactive contexts.
rclone_pass_path="$HOME/.config/nucleus/secrets/rclone-config-pass"
if [ -s "$rclone_pass_path" ]; then
  rclone_config_pass_value="$(cat "$rclone_pass_path")"
  export RCLONE_CONFIG_PASS="$rclone_config_pass_value"
fi

username="$(id -un)"
current_os="$(uname -s)"

replica_lines="$({
  jq -r --arg username "$username" '
    .[$username].cloudDrives.replicas // []
    | map(select(.enable == true and .remoteName != null))
    | .[]
    | [
        (.id // ""),
        (.direction // "bidirectional"),
        (.localPath // ""),
        (.remoteName // ""),
        (.remotePath // "/"),
        (.provider // ""),
        (.iCloudService // "drive"),
        (.filtersFile // "")
      ]
    | @tsv
  ' "$USERS_JSON"
} || true)"

if [ -z "$replica_lines" ]; then
  printf '%s\n' "replica-bisync: no enabled replicas for user '$username'"
  exit 0
fi

run_cmd() {
  if [ "$dry_run" = true ]; then
    printf 'replica-bisync: [dry-run] '
    printf '%s ' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

resolve_filter_path() {
  _candidate="$1"
  case "$_candidate" in
    "")
      printf '%s' ""
      ;;
    ~/*)
      printf '%s' "$HOME/${_candidate#~/}"
      ;;
    /*)
      printf '%s' "$_candidate"
      ;;
    *)
      printf '%s' "$HOME/$_candidate"
      ;;
  esac
}

failures=0
replica_state_dir="$HOME/.config/nucleus/state/replica-bisync"

replica_lines_file="$(mktemp)"
printf '%s\n' "$replica_lines" > "$replica_lines_file"

# shellcheck disable=SC2162  # deliberate tab-split of jq @tsv rows
while IFS="$(printf '\t')" read id direction local_path remote_name remote_path provider icloud_service filters_file; do
  if [ -n "$replica_id_filter" ] && [ "$id" != "$replica_id_filter" ]; then
    continue
  fi

  # macOS iCloudReplica maps to native iCloud-managed storage semantics.
  # Skip the explicit rclone replica pass for this one entry to avoid
  # permission-denied churn while still allowing other replicas to converge.
  if [ "$current_os" = "Darwin" ] && [ "$provider" = "iCloud" ] && [ "$id" = "iCloud" ]; then
    printf '%s\n' "replica-bisync: [$id] skipping on macOS (native iCloud handles sync)"
    continue
  fi

  local_dir="$HOME/$local_path"
  remote_ref="$remote_name:$remote_path"
  resolved_filters="$(resolve_filter_path "$filters_file")"
  state_marker="$replica_state_dir/$id.seeded"

  mkdir -p "$local_dir"

  if [ -n "$resolved_filters" ]; then
    if [ ! -f "$resolved_filters" ]; then
      printf '%s\n' "replica-bisync: filters file '$resolved_filters' not found for replica '$id'" >&2
      failures=$((failures + 1))
      continue
    fi
  fi

  # Build shared rclone arguments once per replica so provider-specific safety
  # filters stay identical across pull/push/bisync code paths.
  set -- --log-level ERROR
  if [ "$provider" = "iCloud" ]; then
    set -- "$@" --iclouddrive-service "$icloud_service"
  fi
  if [ "$provider" = "OneDrive" ]; then
    # Microsoft exposes Personal Vault through the root listing even when the
    # API later rejects traversal. Exclude it proactively so post-apply bisync
    # stays reliable instead of failing every run on invalidResourceId.
    set -- "$@" --exclude "Personal Vault" --exclude "Personal Vault/**"
  fi
  if [ -n "$resolved_filters" ]; then
    set -- "$@" --filter-from "$resolved_filters"
  fi

  case "$direction" in
    pull)
      printf '%s\n' "replica-bisync: [$id] pull $remote_ref -> $local_dir"
      if ! run_cmd rclone sync "$remote_ref" "$local_dir" "$@"; then
        failures=$((failures + 1))
      fi
      ;;
    push)
      printf '%s\n' "replica-bisync: [$id] push $local_dir -> $remote_ref"
      if ! run_cmd rclone sync "$local_dir" "$remote_ref" "$@"; then
        failures=$((failures + 1))
      fi
      ;;
    bidirectional)
      printf '%s\n' "replica-bisync: [$id] bisync $local_dir <-> $remote_ref"
      if [ -f "$state_marker" ]; then
        # Seeded: use --check-access for safety; RCLONE_TEST files already exist.
        # WHY no --resilient/--recover: they cause rclone to continue indefinitely
        # on persistent errors instead of failing fast. --timeout/--contimeout
        # bound each operation to prevent hangs.
        if ! run_cmd rclone bisync "$local_dir" "$remote_ref" \
            --check-access --conflict-resolve newer --max-lock 2m \
            --timeout 60s --contimeout 15s "$@"; then
          printf '%s\n' "replica-bisync: [$id] bisync failed" >&2
          failures=$((failures + 1))
        fi
      else
        # Seed run: --resync WITHOUT --check-access because rclone creates the
        # RCLONE_TEST access marker files during --resync; checking for them
        # first would always fail (chicken-and-egg). Subsequent runs enforce
        # --check-access.
        if ! run_cmd rclone bisync "$local_dir" "$remote_ref" \
            --resync --conflict-resolve newer --max-lock 2m \
            --timeout 60s --contimeout 15s "$@"; then
          failures=$((failures + 1))
        else
          mkdir -p "$replica_state_dir"
          : > "$state_marker"
        fi
      fi
      ;;
    *)
      printf '%s\n' "replica-bisync: unsupported direction '$direction' for replica '$id'" >&2
      failures=$((failures + 1))
      ;;
  esac
done < "$replica_lines_file"

rm -f "$replica_lines_file"

if [ "$failures" -gt 0 ]; then
  printf '%s\n' "replica-bisync: completed with $failures failure(s)" >&2
  exit 1
fi

printf '%s\n' "replica-bisync: completed successfully"
