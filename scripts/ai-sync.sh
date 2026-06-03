#!/usr/bin/env sh
# Override OLLAMA_HOST to point directly at Ollama (not LiteLLM) so that
# model list/pull/rm commands talk to the inference backend directly instead
# of routing through the AI gateway proxy.  The default session variable in
# modules/ai/default.nix points at LiteLLM (127.0.0.1:4000).
export OLLAMA_HOST="127.0.0.1:11434"

# Synchronises locally installed Ollama models with the declarative manifest
# at src/modules/ai/models.json.
#
# Operations:
#   1. Determine the active profile (mac or pc) from the current OS or
#      OLLAMA_PROFILE override.
#   2. Pull any model in the manifest that is not already installed.
#   3. Remove any locally installed model that is not in the manifest.
#      (--prune-only skips step 2 so only removals happen.)
#
# Arguments:
#   --dry-run                            print planned actions without executing them (default: off)
#   --prune-only                         skip pulls; only remove unlisted models (default: off)
#   --server-ready-timeout-seconds N     bounded wait for server readiness (default: 60)
#   --server-ready-poll-seconds N        poll interval while waiting (default: 2)
#
# Environment variables:
#   OLLAMA_PROFILE  override profile selection (MacBook|NixOS|Windows); detected
#                   automatically when unset (Darwin → MacBook, Linux → NixOS)
#   OLLAMA_HOST     Ollama server address; defaults to 127.0.0.1:11434
#
# Exit conditions:
#   0 on success or when ollama is unavailable (benign skip).
#   Non-zero when jq is unavailable or when a pull/remove step fails.

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
MANIFEST="$REPO_ROOT/src/modules/ai/models.json"

dry_run=false
prune_only=false
ready_timeout_seconds=60
ready_poll_seconds=2

usage() {
  cat <<'EOF'
usage: ai-sync.sh [options]

  --dry-run                          Print planned actions without executing them (default: off).
  --prune-only                       Skip pulls; only remove unlisted models (default: off).
  --server-ready-timeout-seconds N   Bounded wait for server readiness (default: 60).
                                     Set to 0 to disable waiting.
  --server-ready-poll-seconds N      Poll interval while waiting (default: 2).
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --dry-run)
      dry_run=true
      ;;
    --prune-only)
      prune_only=true
      ;;
    --server-ready-timeout-seconds)
      if [ -z "${2-}" ] || ! [ "$2" -eq "$2" ] 2>/dev/null || [ "$2" -lt 0 ]; then
        printf '%s\n' "ai-sync: --server-ready-timeout-seconds requires a non-negative integer" >&2
        exit 1
      fi
      ready_timeout_seconds="$2"
      shift
      ;;
    --server-ready-poll-seconds)
      if [ -z "${2-}" ] || ! [ "$2" -eq "$2" ] 2>/dev/null || [ "$2" -le 0 ]; then
        printf '%s\n' "ai-sync: --server-ready-poll-seconds requires a positive integer" >&2
        exit 1
      fi
      ready_poll_seconds="$2"
      shift
      ;;
    *)
      printf '%s\n' "ai-sync: unsupported argument '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

# Determine the active model profile.  OLLAMA_PROFILE env var overrides
# auto-detection so callers can test a non-native profile without changing OS.
if [ -n "${OLLAMA_PROFILE:-}" ]; then
  profile="$OLLAMA_PROFILE"
else
  case "$(uname)" in
    Darwin) profile="MacBook" ;;
    *)      profile="NixOS"   ;;
  esac
fi

# Wait briefly for the Ollama daemon to become responsive after a fresh apply.
# The service process may be installed/registered before the HTTP API is ready,
# so an immediate `ollama list` can race the daemon startup on all POSIX hosts.
wait_for_ollama_server() {
  if ollama list >/dev/null 2>&1; then
    return 0
  fi

  if [ "$ready_timeout_seconds" -eq 0 ]; then
    return 1
  fi

  printf '%s\n' "ai-sync: waiting up to ${ready_timeout_seconds}s for ollama server readiness..."
  _waited=0
  while [ "$_waited" -lt "$ready_timeout_seconds" ]; do
    sleep "$ready_poll_seconds"
    _waited=$((_waited + ready_poll_seconds))
    if ollama list >/dev/null 2>&1; then
      return 0
    fi
  done

  return 1
}

# Fail fast if jq is unavailable: the manifest is JSON and the rest of the
# script depends on jq for reliable parsing.
if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' "ai-sync: jq not found; cannot parse manifest" >&2
  exit 1
fi

# Skip the entire sync when ollama is not installed or the server is not
# running.  This is an expected and benign state on machines where the AI
# module has just been provisioned but ollama has not yet started, or on CI
# images.  The exit-code check afterward (implicit via set -e) ensures that
# any unexpected `ollama list` failure — such as a crashed server — still
# surfaces as an error.
if ! command -v ollama >/dev/null 2>&1; then
  printf '%s\n' "ai-sync: ollama not found; skipping sync"
  exit 0
fi
# Test probe: `ollama list` exits non-zero when the server is unreachable.
# Wait for a bounded period after apply so first-run daemon startup races do
# not silently skip model pulls on otherwise healthy hosts.
if ! wait_for_ollama_server; then
  printf '%s\n' "ai-sync: ollama server unavailable after waiting ${ready_timeout_seconds}s; skipping sync"
  exit 0
fi

# Build the desired model list from the manifest for the active profile.
desired_models=$(jq -r --arg profile "$profile" '.models[$profile][]' "$MANIFEST")

# Build the installed model list from `ollama list` output.
# Output format: NAME  ID  SIZE  MODIFIED (tab/space separated header + rows).
# NR>1 skips the header line; $1!="" guards against blank trailing lines.
installed_models=$(ollama list | awk 'NR>1 && $1!="" {print $1}')

# Pull models present in the manifest but not locally installed.
if [ "$prune_only" = false ]; then
  printf '%s\n' "$desired_models" | while IFS= read -r model; do
    if [ -z "$model" ]; then
      continue
    fi
    if printf '%s\n' "$installed_models" | grep -Fxq "$model"; then
      continue
    fi
    if [ "$dry_run" = true ]; then
      printf '%s\n' "ai-sync: would pull $model"
    else
      printf '%s\n' "ai-sync: pulling $model"
      ollama pull "$model"
    fi
  done
fi

# Remove models that are locally installed but absent from the manifest.
# The manifest is the single source of truth: any model not listed here is
# considered orphaned and is removed to reclaim disk space.
printf '%s\n' "$installed_models" | while IFS= read -r model; do
  if [ -z "$model" ]; then
    continue
  fi
  if printf '%s\n' "$desired_models" | grep -Fxq "$model"; then
    continue
  fi
  if [ "$dry_run" = true ]; then
    printf '%s\n' "ai-sync: would remove $model"
  else
    printf '%s\n' "ai-sync: removing $model"
    ollama rm "$model"
  fi
done

_summary_flags=""
if [ "$dry_run" = true ]; then
  _summary_flags=", not actually running due to --dry-run"
fi
if [ "$prune_only" = true ]; then
  _summary_flags="${_summary_flags}, prune-only mode (no pulls)"
fi

printf '%s\n' "ai-sync: sync completed (profile=$profile${_summary_flags})"
