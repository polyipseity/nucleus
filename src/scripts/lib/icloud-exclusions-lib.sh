# iCloud exclusion convergence for directories matching configured names.
# Called by activation hook and daily launchd agent.
#
# Environment variables:
#   JQ_BIN              — path to jq binary
#   FIND_BIN            — path to findutils find binary
#   EXCLUDED_DIRS_JSON  — JSON array of directory names to exclude
#   MANAGED_ROOTS_JSON  — JSON array of iCloud managed root paths (relative to $HOME)

set -eu

if [ "$EXCLUDED_DIRS_JSON" = "[]" ]; then
  echo "macos: iCloud exclusions skipped (no excluded directory names configured)." >&2
  return 0 2>/dev/null || exit 0
fi

apply_exclusions() {
  local count=0
  local start_time
  start_time=$(date +%s)

  while IFS= read -r rel_root; do
    [ -z "$rel_root" ] && continue
    icloud_root="$HOME/$rel_root"
    [ -d "$icloud_root" ] || continue

    find_args=()
    first=1
    while IFS= read -r dir_name; do
      [ -z "$dir_name" ] && continue
      if [ "$first" -eq 1 ]; then
        find_args=( "(" "-name" "$dir_name" "-exec" "/usr/bin/xattr" "-w" "com.apple.fileprovider.ignore#P" "1" "{}" ";" "-prune" )
        first=0
      else
        find_args+=( "-o" "-name" "$dir_name" "-exec" "/usr/bin/xattr" "-w" "com.apple.fileprovider.ignore#P" "1" "{}" ";" "-prune" )
      fi
    done < <(echo "$EXCLUDED_DIRS_JSON" | "$JQ_BIN" -r '.[]' 2>/dev/null)

    if [ "$first" -eq 1 ]; then
      continue
    fi

    find_args+=( ")" )

    count_batch=$("$FIND_BIN" "$icloud_root" -type d "${find_args[@]}" -print 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ') || count_batch=0
    count=$(( count + count_batch ))
  done < <(echo "$MANAGED_ROOTS_JSON" | "$JQ_BIN" -r '.[]' 2>/dev/null)

  end_time=$(date +%s)
  elapsed=$(( end_time - start_time ))

  if [ "$count" -gt 0 ]; then
    echo "macos: iCloud exclusion applied to $count directories in ${elapsed}s" >&2
  fi
}

apply_exclusions
