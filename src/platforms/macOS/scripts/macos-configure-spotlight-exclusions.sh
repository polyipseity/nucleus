#!/usr/bin/env bash
# Daily Spotlight exclusion refresh for the mutable ~/dev tree.
# Directory names to exclude are passed as space-separated $1.
set -eu

DEV_ROOT="$HOME/dev"
updated_count=0

# Create the canonical dev root lazily so the maintenance timer remains
# safe even before the first repo checkout populates ~/dev.
mkdir -p "$DEV_ROOT"

# Build find predicate from space-separated directory names.
# Names are Nix-controlled ASCII without special characters.
_find_args=()
# shellcheck disable=SC2086 # reason: word splitting intentional for space-separated names from Nix
for _name in ${SPOTLIGHT_EXCLUDED_DIR_NAMES:-${1:?usage: macos-configure-spotlight-exclusions.sh '<name> [name ...]>'}}; do
  _find_args+=(-name "$_name" -o)
done
# Remove trailing -o
unset '_find_args[${#_find_args[@]}-1]'

while IFS= read -r -d "" directory_path; do
  marker_path="$directory_path/.metadata_never_index"
  if [ -f "$marker_path" ]; then
    continue
  fi

  : >"$marker_path"
  updated_count=$((updated_count + 1))
done < <(
  /usr/bin/find "$DEV_ROOT" \( "${_find_args[@]}" \) -type d -print0
)

if [ "$updated_count" -gt 0 ]; then
  echo "macos: added Spotlight exclusion markers to $updated_count dev directories." >&2
fi
