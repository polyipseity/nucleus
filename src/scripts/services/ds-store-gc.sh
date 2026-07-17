# Daily Finder .DS_Store cleanup for ~/dev.
set -eu

DEV_ROOT="$HOME/dev"
removed_count=0

# Create the canonical dev root lazily so the maintenance timer remains
# safe even before the first repo checkout populates ~/dev.
mkdir -p "$DEV_ROOT"

while IFS= read -r -d "" ds_store_path; do
  /bin/rm "$ds_store_path"
  removed_count=$((removed_count + 1))
done < <(
  /usr/bin/find "$DEV_ROOT" -name ".DS_Store" -type f -print0
)

if [ "$removed_count" -gt 0 ]; then
  echo "macos: removed $removed_count .DS_Store files from ~/dev." >&2
fi
