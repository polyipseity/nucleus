#!/usr/bin/env bash
# iCloud exclusion convergence for directories matching configured names.
# Called by activation hook and daily launchd agent.
#
# apply_exclusions JQ_BIN FIND_BIN EXCLUDED_DIRS_JSON MANAGED_ROOTS_JSON
# Returns 0 on success, 1 on error.

# Source lib.sh from this library's own directory (callers set SCRIPT_DIR to
# their own location, so resolve relative to this file).
_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
. "$_LIB_DIR/lib.sh"
unset _LIB_DIR

apply_exclusions() {
  local jq_bin="$1"
  local find_bin="$2"
  local excluded_dirs_json="$3"
  local managed_roots_json="$4"
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
        find_args=("(" "-name" "$dir_name" "-exec" "/usr/bin/xattr" "-w" "com.apple.fileprovider.ignore#P" "1" "{}" ";" "-prune")
        first=0
      else
        find_args+=("-o" "-name" "$dir_name" "-exec" "/usr/bin/xattr" "-w" "com.apple.fileprovider.ignore#P" "1" "{}" ";" "-prune")
      fi
    done < <(echo "$excluded_dirs_json" | "$jq_bin" -r '.[]' 2>/dev/null)

    if [ "$first" -eq 1 ]; then
      continue
    fi

    find_args+=(")")

    count_batch=$("$find_bin" "$icloud_root" -type d "${find_args[@]}" -print 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ') || count_batch=0
    count=$((count + count_batch))
  done < <(echo "$managed_roots_json" | "$jq_bin" -r '.[]' 2>/dev/null)

  end_time=$(date +%s)
  elapsed=$((end_time - start_time))

  if [ "$count" -gt 0 ]; then
    say "iCloud exclusion applied to $count directories in ${elapsed}s"
  fi
}
