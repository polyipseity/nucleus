#!/usr/bin/env bash
# generate-winget-lockfile.sh — Query winget-pkgs manifests and populate the
# winget section in lockfile.json.
#
# This script extracts WinGet package IDs from system.dsc.yml, discovers the
# latest version for each package from the microsoft/winget-pkgs GitHub
# repository (via the GitHub API), and writes the updated lockfile atomically.
#
# Usage:
#   generate-winget-lockfile.sh
#
# Environment variables:
#   NUCLEUS_REPO_ROOT  Override the detected repository root path.
#   GITHUB_TOKEN       GitHub token for API authentication (optional but
#                      strongly recommended to avoid rate limiting).
#
# Exit conditions:
#   0 on success; non-zero on failure (missing jq/yq, missing DSC files).
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../src/scripts/lib.sh"

REPO_ROOT="$(resolve_nucleus_root)"
LOCKFILE_REL="src/lockfiles/lockfile.json"
LOCKFILE_ABS="$REPO_ROOT/$LOCKFILE_REL"
DSC_SYSTEM="$REPO_ROOT/src/hosts/Windows/system.dsc.yml"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
require_command jq
require_command yq

if [ ! -f "$DSC_SYSTEM" ]; then
  printf '%s\n' "generate-winget-lockfile: error: system.dsc.yml not found at $DSC_SYSTEM" >&2
  exit 1
fi

if [ ! -f "$LOCKFILE_ABS" ]; then
  printf '%s\n' "generate-winget-lockfile: error: lockfile not found at $LOCKFILE_ABS" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# GitHub API helper
# ---------------------------------------------------------------------------
GITHUB_API_BASE="https://api.github.com/repos/microsoft/winget-pkgs/contents/manifests"
CURL_OPTS=(-sfL)
if [ -n "${GITHUB_TOKEN:-}" ]; then
  CURL_OPTS+=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

# Get the latest version directory from a package manifest path.
# Winget manifests follow: manifests/{first}/{publisher}/{package}/
# Returns the latest (alphabetically last) version directory.
_latest_winget_version() {
  local publisher="$1"
  local package="$2"
  local first_char="${publisher:0:1}"
  first_char="${first_char,,}"  # lowercase first char

  local url="$GITHUB_API_BASE/${first_char}/${publisher}/${package}"
  local versions
  versions=$(curl "${CURL_OPTS[@]}" "$url" 2>/dev/null | jq -r '.[].name // empty' | sort -V 2>/dev/null || true)
  if [ -z "$versions" ]; then
    return 1
  fi
  echo "$versions" | tail -1
}

# ---------------------------------------------------------------------------
# Extract winget package IDs from DSC YAML
# ---------------------------------------------------------------------------
printf 'generate-winget-lockfile: extracting winget package IDs from DSC...\n'

# Extract all winget Package resource IDs
mapfile -t MAPFILE_IDS < <(yq eval '.properties.resources[] | select(.resource == "Microsoft.WinGet.Client/Package") | .settings.id' "$DSC_SYSTEM")

# Filter to only winget-source packages (exclude msstore)
WINGET_IDS=()
for _id in "${MAPFILE_IDS[@]}"; do
  _source=$(yq eval ".properties.resources[] | select(.resource == \"Microsoft.WinGet.Client/Package\" and .settings.id == \"$_id\") | .settings.source" "$DSC_SYSTEM")
  if [ "$_source" = "winget" ]; then
    WINGET_IDS+=("$_id")
  fi
done

if [ "${#WINGET_IDS[@]}" -eq 0 ]; then
  printf '%s\n' "generate-winget-lockfile: no winget packages found in DSC"
  exit 0
fi

printf 'generate-winget-lockfile: found %d winget packages\n' "${#WINGET_IDS[@]}"

# ---------------------------------------------------------------------------
# Discover versions
# ---------------------------------------------------------------------------
declare -A NEW_VERSIONS

for _id in "${WINGET_IDS[@]}"; do
  # Convert package ID to publisher/package path components
  _publisher="${_id%.*}"
  _package="${_id##*.}"

  _current_ver=""
  if jq -e ".winget | has(\"$_id\")" "$LOCKFILE_ABS" >/dev/null 2>&1; then
    _current_ver=$(jq -r ".winget.\"$_id\"" "$LOCKFILE_ABS")
  fi

  printf '  %s: ' "$_id"

  if _latest_ver=$(_latest_winget_version "$_publisher" "$_package"); then
    printf 'found %s' "$_latest_ver"
    if [ "$_latest_ver" != "$_current_ver" ]; then
      printf ' (was %s)' "${_current_ver:-<unset>}"
      NEW_VERSIONS["$_id"]="$_latest_ver"
    fi
    printf '\n'
  else
    printf 'not found in winget-pkgs (skipping)\n'
  fi
done

# ---------------------------------------------------------------------------
# Write updated lockfile
# ---------------------------------------------------------------------------
if [ "${#NEW_VERSIONS[@]}" -gt 0 ]; then
  printf '\ngenerate-winget-lockfile: updating lockfile with %d version(s)...\n' "${#NEW_VERSIONS[@]}"

  # Build jq args for each update: --arg k0 <id0> --arg v0 <ver0> ...
  JQ_ARGS=()
  JQ_SET=()
  _idx=0
  for _id in "${!NEW_VERSIONS[@]}"; do
    JQ_ARGS+=(--arg "k$_idx" "$_id" --arg "v$_idx" "${NEW_VERSIONS[$_id]}")
    JQ_SET+=(".[\$k$_idx] = \$v$_idx")
    _idx=$((_idx + 1))
  done

  _set_expr=$(IFS=' | '; echo "${JQ_SET[*]}")
  _tmpf=$(mktemp)
  jq "${JQ_ARGS[@]}" ".winget |= (. // {} | $_set_expr)" "$LOCKFILE_ABS" > "$_tmpf"
  mv "$_tmpf" "$LOCKFILE_ABS"

  printf 'generate-winget-lockfile: lockfile updated (%s)\n' "$LOCKFILE_REL"
else
  printf '\ngenerate-winget-lockfile: no updates needed\n'
fi
