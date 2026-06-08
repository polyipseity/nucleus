#!/usr/bin/env bash
# generate-winget-locked-dsc.sh — Produce system-locked.dsc.yml by merging
# version pins from lockfile.json into system.dsc.yml.
#
# For each Microsoft.WinGet.Client/Package resource with source=winget, looks
# up the package ID in the lockfile winget section.  If a version is found,
# adds a `version` field under `settings`.  msstore packages are left
# unmodified (version pinning is only meaningful for winget-source packages).
# The original system.dsc.yml is never modified.
#
# Usage:
#   generate-winget-locked-dsc.sh
#
# Environment variables:
#   NUCLEUS_REPO_ROOT  Override the detected repository root path.
#
# Output:
#   Writes system-locked.dsc.yml next to system.dsc.yml.  Exits 0 on
#   success, non-zero on failure (missing jq/yq, missing inputs).
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../src/scripts/lib.sh"

REPO_ROOT="$(resolve_nucleus_root)"
LOCKFILE_ABS="$REPO_ROOT/src/lockfiles/lockfile.json"
DSC_IN="$REPO_ROOT/src/hosts/Windows/system.dsc.yml"
DSC_OUT="$REPO_ROOT/src/hosts/Windows/system-locked.dsc.yml"

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
require_command jq
require_command yq

for f in "$DSC_IN" "$LOCKFILE_ABS"; do
  if [ ! -f "$f" ]; then
    printf '%s\n' "generate-winget-locked-dsc: error: $f not found" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Build a lookup map: winget id → version from lockfile
# ---------------------------------------------------------------------------
# Read lockfile's winget section as a JSON object reference for jq
LOCKED_JSON="$(jq -c '.winget // {}' "$LOCKFILE_ABS")"
if [ "$LOCKED_JSON" = '{}' ]; then
  printf '%s\n' 'generate-winget-locked-dsc: warning: lockfile winget section is empty; writing DSC without version pins'
fi

# ---------------------------------------------------------------------------
# Generate locked DSC via yq → jq → yq pipeline
#
# Read DSC as JSON, merge lockfile versions into winget Package resources,
# write to output file.  The original DSC is never modified.
# ---------------------------------------------------------------------------
printf 'generate-winget-locked-dsc: generating locked DSC...\n'

_tmpf=$(mktemp)

yq eval -o=j '.' "$DSC_IN" | \
jq --argjson locked "$LOCKED_JSON" '
  .properties.resources |= [
    .[] | if .resource == "Microsoft.WinGet.Client/Package" and .settings.source == "winget" and ($locked[.settings.id] | length > 0) then
      .settings.version = $locked[.settings.id]
    else
      .
    end
  ]
' | \
yq eval -P '.' - > "$_tmpf"

# Count version pins applied
_pin_count=$(jq '[.properties.resources[] | select(.settings.version != null)] | length' "$_tmpf")

mv "$_tmpf" "$DSC_OUT"

printf 'generate-winget-locked-dsc: wrote %s (%d version pins)\n' "$DSC_OUT" "$_pin_count"
