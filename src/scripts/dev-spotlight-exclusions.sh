# Daily Spotlight exclusion refresh for the mutable ~/dev tree.
# Uses a Nix-generated find predicate expression (DEV_SPOTLIGHT_FIND_EXPRESSION)
# that is substituted at eval time.
set -eu

DEV_ROOT="$HOME/dev"
updated_count=0

# Create the canonical dev root lazily so the maintenance timer remains
# safe even before the first repo checkout populates ~/dev.
mkdir -p "$DEV_ROOT"

while IFS= read -r -d "" directory_path; do
  marker_path="$directory_path/.metadata_never_index"
  if [ -f "$marker_path" ]; then
    continue
  fi

  : > "$marker_path"
  updated_count=$((updated_count + 1))
done < <(
  /usr/bin/find "$DEV_ROOT" \( DEV_SPOTLIGHT_FIND_EXPRESSION \) -type d -print0
)

if [ "$updated_count" -gt 0 ]; then
  echo "macos: added Spotlight exclusion markers to $updated_count dev directories." >&2
fi
