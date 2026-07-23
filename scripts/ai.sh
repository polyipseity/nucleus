#!/usr/bin/env bash
# Provides a uniform CLI for AI model management: sync, list, status, endpoint,
# and config across POSIX hosts (macOS, NixOS).  Reads models.json for
# declarative model selection and services.json for service endpoints.

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
# shellcheck source=../src/scripts/lib/lib.sh
. "$SCRIPT_DIR/../src/scripts/lib/lib.sh"

REPO_ROOT="$(derive_repo_root)"
MANIFEST="$REPO_ROOT/src/modules/ai/models.json"
LOCKFILE="$REPO_ROOT/src/lockfiles/lockfile.json"
SERVICES_JSON="$REPO_ROOT/src/modules/services.json"
HOST="$(resolve_nucleus_host)"

usage() {
  usage_std "$(basename "$0")" "sync|list|status|endpoint|config [options]"
  cat <<'EOF'
  sync                              Pull models and remove orphans.
  list                              List AI models by profile.
  status                            Show AI service and model sync status.
  endpoint                          Show AI service endpoints.
  config                            Show effective AI configuration.

  Options:
    --json                          Machine-readable JSON output.
    -h|--help                       Show usage.

  sync options:
    --dry-run                       Print planned actions without executing them.
    --gc-only                       Skip pulls, only remove orphans.
    --ollama-profile <name>         Override profile selection (MacBook|NixOS|Windows).

  list options:
    --profile <name>                Filter to a specific profile.

  status options:
    --json                          Machine-readable JSON output.
EOF
}

# ──────────────────────────────────────────────────────────────────────────────
# sync subcommand — preserve all logic from ai-sync.sh verbatim
# ──────────────────────────────────────────────────────────────────────────────

ready_timeout_seconds="${NUCLEUS_AI_SYNC_TIMEOUT:-60}"
ready_poll_seconds="${NUCLEUS_AI_SYNC_POLL:-2}"
NUCLEUS_OLLAMA_HOST="${NUCLEUS_OLLAMA_HOST:-$(jq -r '.ollama.network.default | "\(.host):\(.port)"' "$SERVICES_JSON" 2>/dev/null || echo "127.0.0.1:11434")}"

# wait_for_ollama_server — Poll until ollama responds or timeout.
wait_for_ollama_server() {
  if OLLAMA_HOST="$NUCLEUS_OLLAMA_HOST" ollama list >/dev/null 2>&1; then
    return 0
  fi

  if [ "$ready_timeout_seconds" -eq 0 ]; then
    return 1
  fi

  say "waiting up to ${ready_timeout_seconds}s for ollama server readiness..."
  _waited=0
  while [ "$_waited" -lt "$ready_timeout_seconds" ]; do
    sleep "$ready_poll_seconds"
    _waited=$((_waited + ready_poll_seconds))
    if OLLAMA_HOST="$NUCLEUS_OLLAMA_HOST" ollama list >/dev/null 2>&1; then
      return 0
    fi
  done

  return 1
}

do_sync() {
  _sync_dry_run=false
  _sync_gc_only=false
  _sync_profile_override=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run)
        _sync_dry_run=true
        ;;
      --ollama-profile)
        _sync_profile_override="$2"
        shift
        ;;
      --gc-only)
        _sync_gc_only=true
        ;;
      --no-gc-only)
        _sync_gc_only=false
        ;;
      --json)
        # sync ignores --json; it always outputs human-readable messages
        ;;
      *)
        error "sync: unsupported argument '$1'"
        usage >&2
        exit 1
        ;;
    esac
    shift
  done

  # Determine the active model profile.
  if [ -n "$_sync_profile_override" ]; then
    profile="$_sync_profile_override"
  elif [ -n "${NUCLEUS_AI_SYNC_PROFILE:-}" ]; then
    profile="$NUCLEUS_AI_SYNC_PROFILE"
  else
    case "$(uname)" in
      Darwin) profile="MacBook" ;;
      *)      profile="NixOS"   ;;
    esac
  fi

  # Fail fast if jq is unavailable.
  if ! command -v jq >/dev/null 2>&1; then
    error "jq not found; cannot parse manifest"
  fi

  if ! command -v ollama >/dev/null 2>&1; then
    say "ollama not found; skipping sync"
    exit 0
  fi
  if ! wait_for_ollama_server; then
    say "ollama server unavailable after waiting ${ready_timeout_seconds}s; skipping sync"
    exit 0
  fi

  # Build the desired model list from the manifest for the active profile.
  desired_models=$(jq -r --arg profile "$profile" '.models[$profile][]' "$MANIFEST")

  # Build the installed model list from `ollama list` output.
  installed_models=$(OLLAMA_HOST="$NUCLEUS_OLLAMA_HOST" ollama list | awk 'NR>1 && $1!="" {print $1}')

  if [ "$_sync_gc_only" = false ]; then
    printf '%s\n' "$desired_models" | while IFS= read -r model; do
      if [ -z "$model" ]; then
        continue
      fi
      if printf '%s\n' "$installed_models" | grep -Fxq "$model"; then
        continue
      fi
      if [ "$_sync_dry_run" = true ]; then
        dry_run "would pull $model"
      else
        say "pulling $model"
        OLLAMA_HOST="$NUCLEUS_OLLAMA_HOST" ollama pull "$model"
        if ! printf '%s\n' "$(OLLAMA_HOST="$NUCLEUS_OLLAMA_HOST" ollama list | awk 'NR>1 && $1!="" {print $1}')" | grep -Fxq "$model"; then
          error "$model was pulled but is not in 'ollama list'"
        fi
        if [ -f "$LOCKFILE" ]; then
          _model_name="${model%%:*}"
          _model_tag="${model#*:}"
          [ "$_model_tag" = "$model" ] && _model_tag="latest"
          # shellcheck disable=SC2016 # reason: jq filter variables use $p, $n, $t — not shell expansion
          _expected_digest=$(jq -r --arg p "$profile" --arg n "$_model_name" --arg t "$_model_tag" '
            .ollama[$p][] | select(.name == $n and .tag == $t) | .digest // empty' "$LOCKFILE" 2>/dev/null || true) # check-suppress:suppression_doc: model may not be pulled yet; digest probe expected to fail.
          if [ -n "$_expected_digest" ]; then
            _actual_digest=$(OLLAMA_HOST="$NUCLEUS_OLLAMA_HOST" ollama show --format json "$model" 2>/dev/null | jq -r '.digest // empty' 2>/dev/null || true) # check-suppress:suppression_doc: model may not be pulled yet; digest probe expected to fail.
            if [ -n "$_actual_digest" ] && [ "$_actual_digest" != "$_expected_digest" ]; then
              warn "digest mismatch for $model (expected $_expected_digest, got $_actual_digest)"
            elif [ -n "$_actual_digest" ]; then
              say "digest verified for $model"
            fi
          fi
        fi
      fi
    done
  fi

  # Remove models that are locally installed but absent from the manifest.
  printf '%s\n' "$installed_models" | while IFS= read -r model; do
    if [ -z "$model" ]; then
      continue
    fi
    if printf '%s\n' "$desired_models" | grep -Fxq "$model"; then
      continue
    fi
    if [ "$_sync_dry_run" = true ]; then
      dry_run "would remove $model"
    else
      say "removing $model"
      OLLAMA_HOST="$NUCLEUS_OLLAMA_HOST" ollama rm "$model"
    fi
  done

  _summary_flags=""
  if [ "$_sync_dry_run" = true ]; then
    _summary_flags=", not actually running due to --dry-run"
  fi
  if [ "$_sync_gc_only" = true ]; then
    _summary_flags="${_summary_flags}, gc-only mode (no pulls)"
  fi

  say "sync completed (profile=$profile${_summary_flags})"
}

# ──────────────────────────────────────────────────────────────────────────────
# list subcommand
# ──────────────────────────────────────────────────────────────────────────────

do_list() {
  _list_profile=""
  _list_json=false

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --profile)
        _list_profile="$2"
        shift
        ;;
      --json)
        _list_json=true
        ;;
      *)
        error "list: unsupported argument '$1'"
        usage >&2
        exit 1
        ;;
    esac
    shift
  done

  if ! command -v jq >/dev/null 2>&1; then
    error "jq not found; cannot parse manifest"
  fi
  if [ ! -f "$MANIFEST" ]; then
    error "models manifest not found at $MANIFEST"
  fi

  if [ -n "$_list_profile" ]; then
    if [ "$_list_json" = true ]; then
      jq -c --arg profile "$_list_profile" '{profile: $profile, models: .models[$profile]}' "$MANIFEST"
    else
      printf 'Profile: %s\n' "$_list_profile"
      printf '%.0s-' {1..50}; printf '\n'
      jq -r --arg profile "$_list_profile" '.models[$profile][] // empty' "$MANIFEST" | while IFS= read -r model; do
        printf '  %s\n' "$model"
      done
    fi
  else
    if [ "$_list_json" = true ]; then
      jq -c '{profiles: [.models | to_entries[] | {profile: .key, models: .value}]}' "$MANIFEST"
    else
      printf '%-12s %s\n' "Profile" "Models"
      printf '%.0s-' {1..60}; printf '\n'
      jq -r '.models | to_entries[] | .key' "$MANIFEST" | while IFS= read -r profile_name; do
        _models=$(jq -r --arg p "$profile_name" '.models[$p][]' "$MANIFEST" | tr '\n' ', ' | sed 's/, $//')
        printf '%-12s %s\n' "$profile_name" "$_models"
      done
    fi
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# status subcommand
# ──────────────────────────────────────────────────────────────────────────────

do_status() {
  _status_json=false

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json)
        _status_json=true
        ;;
      *)
        error "status: unsupported argument '$1'"
        usage >&2
        exit 1
        ;;
    esac
    shift
  done

  # Probe ollama availability.
  _ollama_available=false
  _ollama_responding=false

  if command -v ollama >/dev/null 2>&1; then
    _ollama_available=true
    # shellcheck disable=SC2086 # reason: word splitting intentional for OLLAMA_HOST env var prefix
    if OLLAMA_HOST="$NUCLEUS_OLLAMA_HOST" ollama list >/dev/null 2>&1; then
      _ollama_responding=true
    fi
  fi

  if [ "$_status_json" = true ]; then
    # Build JSON output.
    _svc_json=$(jq -n --arg host "$HOST" \
      --arg ollama_available "$_ollama_available" \
      --arg ollama_responding "$_ollama_responding" \
      '{version: 1, host: $host, ollama: {available: ($ollama_available == "true"), responding: ($ollama_responding == "true")}}')

    if [ "$_ollama_responding" = true ]; then
      _desired_count=$(jq -r --arg profile "$HOST" '.models[$profile] | length' "$MANIFEST")
      _installed_count=$(OLLAMA_HOST="$NUCLEUS_OLLAMA_HOST" ollama list | awk 'NR>1 && $1!="" {count++} END {print count}')
      _svc_json=$(echo "$_svc_json" | jq --argjson desired "$_desired_count" --argjson installed "$_installed_count" \
        '. + {manifest: {desiredModels: $desired, installedModels: $installed}}')
    fi

    printf '%s\n' "$_svc_json"
  else
    say "host: $HOST"

    if [ "$_ollama_available" = true ]; then
      say "ollama: available"
    else
      say "ollama: not available (binary not found)"
    fi

    if [ "$_ollama_responding" = true ]; then
      say "ollama server: responding"

      # Count desired vs installed models.
      _desired_count=$(jq -r --arg profile "$HOST" '.models[$profile] | length' "$MANIFEST")
      _installed_count=$(OLLAMA_HOST="$NUCLEUS_OLLAMA_HOST" ollama list | awk 'NR>1 && $1!="" {count++} END {print count}')
      say "desired models ($HOST profile): $_desired_count"
      say "installed models: $_installed_count"

      if [ "$_installed_count" -lt "$_desired_count" ]; then
        warn "some models not yet installed — run 'nucleus-ai sync'"
      elif [ "$_installed_count" -gt "$_desired_count" ]; then
        warn "orphan models detected — run 'nucleus-ai sync' to clean up"
      else
        say "model sync: up to date"
      fi
    elif [ "$_ollama_available" = true ]; then
      say "ollama server: not responding"
    fi
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# endpoint subcommand
# ──────────────────────────────────────────────────────────────────────────────

do_endpoint() {
  _endpoint_json=false

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json)
        _endpoint_json=true
        ;;
      *)
        error "endpoint: unsupported argument '$1'"
        usage >&2
        exit 1
        ;;
    esac
    shift
  done

  if ! command -v jq >/dev/null 2>&1; then
    error "jq not found; cannot parse services registry"
  fi
  if [ ! -f "$SERVICES_JSON" ]; then
    error "services registry not found at $SERVICES_JSON"
  fi

  # Extract network endpoints for ollama and litellm.
  if [ "$_endpoint_json" = true ]; then
    jq -c '{ollama: .ollama.network, litellm: .litellm.network}' "$SERVICES_JSON"
  else
    printf '%-10s %-10s %s\n' "Service" "Key" "Endpoint"
    printf '%.0s-' {1..70}; printf '\n'
    for _svc in ollama litellm; do
      # shellcheck disable=SC2016 # reason: jq filter uses $svc — not shell expansion
      _network=$(jq -c --arg svc "$_svc" '.[$svc].network // empty' "$SERVICES_JSON")
      if [ -z "$_network" ]; then
        continue
      fi
      echo "$_network" | jq -r 'to_entries[] | [.key, .value.protocol + "://" + .value.host + ":" + (.value.port|tostring)] | @tsv' | while IFS=$'\t' read -r _ep_key _ep_url; do
        printf '%-10s %-10s %s\n' "$_svc" "$_ep_key" "$_ep_url"
      done
    done
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# config subcommand
# ──────────────────────────────────────────────────────────────────────────────

do_config() {
  _config_json=false

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json)
        _config_json=true
        ;;
      *)
        error "config: unsupported argument '$1'"
        usage >&2
        exit 1
        ;;
    esac
    shift
  done

  if ! command -v jq >/dev/null 2>&1; then
    error "jq not found; cannot parse manifest"
  fi

  if [ "$_config_json" = true ]; then
    # Gather model counts per profile.
    _profiles_json=$(jq -c '[.models | to_entries[] | {profile: .key, count: (.value | length)}]' "$MANIFEST")
    jq -n \
      --arg host "$HOST" \
      --argjson profiles "$_profiles_json" \
      --arg ollama_host "${NUCLEUS_OLLAMA_HOST:-127.0.0.1:11434}" \
      --arg timeout "${NUCLEUS_AI_SYNC_TIMEOUT:-60}" \
      --arg poll "${NUCLEUS_AI_SYNC_POLL:-2}" \
      --arg sync_profile "${NUCLEUS_AI_SYNC_PROFILE:-}" \
      '{version: 1, host: $host, profiles: $profiles, env: {OLLAMA_HOST: $ollama_host, AI_SYNC_TIMEOUT: $timeout, AI_SYNC_POLL: $poll, AI_SYNC_PROFILE: $sync_profile}}'
  else
    say "host: $HOST"
    say "ollama host: ${NUCLEUS_OLLAMA_HOST:-127.0.0.1:11434}"
    say "sync timeout: ${NUCLEUS_AI_SYNC_TIMEOUT:-60}s"
    say "sync poll: ${NUCLEUS_AI_SYNC_POLL:-2}s"
    if [ -n "${NUCLEUS_AI_SYNC_PROFILE:-}" ]; then
      say "sync profile override: $NUCLEUS_AI_SYNC_PROFILE"
    fi

    printf '\n'
    printf '%-12s %s\n' "Profile" "Model Count"
    printf '%.0s-' {1..40}; printf '\n'
    jq -r '.models | to_entries[] | [.key, (.value | length | tostring)] | @tsv' "$MANIFEST" | while IFS=$'\t' read -r _profile_name _count; do
      printf '%-12s %s\n' "$_profile_name" "$_count"
    done
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Main dispatch
# ──────────────────────────────────────────────────────────────────────────────

action="${1:-help}"
case "$action" in
  -h|--help|help) usage; exit 0 ;;
esac
shift 2>/dev/null || true # check-suppress:suppression_doc: shift fails when no args remain (subcommand-only invocation); ignored intentionally

case "$action" in
  sync)     do_sync "$@" ;;
  list)     do_list "$@" ;;
  status)   do_status "$@" ;;
  endpoint) do_endpoint "$@" ;;
  config)   do_config "$@" ;;
  *) error "unsupported subcommand '$action'"; usage >&2; exit 1 ;;
esac
