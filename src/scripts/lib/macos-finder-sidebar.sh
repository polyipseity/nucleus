#!/usr/bin/env bash
# Finder sidebar favorites library. Every function takes its data as parameters; the
# activation script passes Nix-derived values.
_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
. "$_LIB_DIR/lib.sh"
unset _LIB_DIR

# Directories referenced by managed favorites: system-owned ones are created
# unconditionally, managed ones only when neither a directory nor a symlink exists.
finder_ensure_directories() {
  local favorites_json="$1"
  local jq_bin="$2"
  _ensure_tmp=$(mktemp)
  printf '%s\n' "$favorites_json" | "$jq_bin" -r '.[] | .name' >"$_ensure_tmp"
  while IFS= read -r _name; do
    case "$_name" in
    Applications | Desktop | Documents | Downloads | Music | Movies | Pictures)
      mkdir -p "$HOME/$_name"
      ;;
    *)
      if [ ! -d "$HOME/$_name" ] && [ ! -L "$HOME/$_name" ]; then
        mkdir -p "$HOME/$_name"
      fi
      ;;
    esac
  done <"$_ensure_tmp"
  rm -f "$_ensure_tmp"
  unset _ensure_tmp
}

# Pre-remove managed favorites plus the default entries ("/", user home alias,
# ".Trash") that reappear after daemon restarts.
finder_pre_remove() {
  local favorites_json="$1"
  local jq_bin="$2"
  local mysides_bin="$3"
  _pr_tmp=$(mktemp)
  printf '%s\n' "$favorites_json" | "$jq_bin" -r '.[] | .name' >"$_pr_tmp"
  while IFS= read -r _name; do
    # check-suppress:suppression_doc: mysides is known to segfault on corrupted bookmarks; soft-fail prevents activation abort.
    "$mysides_bin" remove "$_name" >/dev/null 2>&1 || true
  done <"$_pr_tmp"
  rm -f "$_pr_tmp"
  # Default extras that reappear after daemon restarts
  # check-suppress:suppression_doc: see finder_pre_remove -- mysides segfaults.
  "$mysides_bin" remove "/" >/dev/null 2>&1 || true
  # check-suppress:suppression_doc: see finder_pre_remove.
  "$mysides_bin" remove "$(id -un)" >/dev/null 2>&1 || true
  # check-suppress:suppression_doc: see finder_pre_remove.
  "$mysides_bin" remove ".Trash" >/dev/null 2>&1 || true
  unset _pr_tmp
}

# Clear every favorite. Uses a temp file: while-read in a pipeline runs in a subshell
# under POSIX sh, so the loop variables would be lost.
finder_clear_all() {
  local mysides_bin="$1"
  _clear_tmp=$(mktemp)
  # check-suppress:suppression_doc: mysides list may segfault on corrupted bookmarks; soft-fail prevents activation abort.
  "$mysides_bin" list 2>/dev/null >"$_clear_tmp" || true
  while IFS= read -r _line; do
    _name="${_line%% -> *}"
    [ -n "$_name" ] || continue
    # check-suppress:suppression_doc: mysides remove may segfault; soft-fail prevents activation abort.
    "$mysides_bin" remove "$_name" >/dev/null 2>&1 || true
  done <"$_clear_tmp"
  rm -f "$_clear_tmp"
  unset _clear_tmp
}

# Add managed favorites, returning 1 if any addition failed.
finder_add_managed_strict() {
  local favorites_json="$1"
  local jq_bin="$2"
  local mysides_bin="$3"
  _add_tmp=$(mktemp)
  printf '%s\n' "$favorites_json" | "$jq_bin" -r '.[] | @base64' >"$_add_tmp"
  _add_failed=0
  while IFS= read -r _item; do
    _jq() { printf '%s\n' "$_item" | base64 -d | "$jq_bin" -r "$1"; }
    _name=$(_jq '.name')
    _url=$(_jq '.url')
    if ! "$mysides_bin" add "$_name" "$_url" >/dev/null 2>&1; then
      warn "failed to add Finder favorite '$_name' ($_url)."
      _add_failed=1
    fi
  done <"$_add_tmp"
  rm -f "$_add_tmp"
  unset _add_tmp _jq
  return "$_add_failed"
}

# Add managed favorites, ignoring failures. Used after the Finder desktop restart.
finder_add_managed_best_effort() {
  local favorites_json="$1"
  local jq_bin="$2"
  local mysides_bin="$3"
  _add_tmp=$(mktemp)
  printf '%s\n' "$favorites_json" | "$jq_bin" -r '.[] | @base64' >"$_add_tmp"
  while IFS= read -r _item; do
    _jq() { printf '%s\n' "$_item" | base64 -d | "$jq_bin" -r "$1"; }
    _name=$(_jq '.name')
    _url=$(_jq '.url')
    # check-suppress:suppression_doc: mysides add may segfault; best-effort add must not abort activation.
    "$mysides_bin" add "$_name" "$_url" >/dev/null 2>&1 || true
  done <"$_add_tmp"
  rm -f "$_add_tmp"
  unset _add_tmp _jq
}

# Default extras that reappear after daemon restarts.
finder_remove_default_extras() {
  local mysides_bin="$1"
  # check-suppress:suppression_doc: mysides is known to segfault on corrupted bookmarks; soft-fail prevents activation abort.
  "$mysides_bin" remove "/" >/dev/null 2>&1 || true
  # check-suppress:suppression_doc: see finder_remove_default_extras -- mysides segfaults.
  "$mysides_bin" remove "$(id -un)" >/dev/null 2>&1 || true
  # check-suppress:suppression_doc: see finder_remove_default_extras.
  "$mysides_bin" remove ".Trash" >/dev/null 2>&1 || true
}

# Strict mode, used during initial activation. Returns 1 if any addition failed.
finder_reconcile_strict() {
  local favorites_json="$1"
  local jq_bin="$2"
  local mysides_bin="$3"
  finder_pre_remove "$favorites_json" "$jq_bin" "$mysides_bin"
  finder_clear_all "$mysides_bin"
  _strict_failed=0
  finder_add_managed_strict "$favorites_json" "$jq_bin" "$mysides_bin" || _strict_failed=1
  finder_remove_default_extras "$mysides_bin"
  return "$_strict_failed"
}

# Best-effort mode, used after the Finder desktop restart.
finder_reconcile_best_effort() {
  local favorites_json="$1"
  local jq_bin="$2"
  local mysides_bin="$3"
  finder_pre_remove "$favorites_json" "$jq_bin" "$mysides_bin"
  finder_clear_all "$mysides_bin"
  finder_add_managed_best_effort "$favorites_json" "$jq_bin" "$mysides_bin"
  finder_remove_default_extras "$mysides_bin"
}

# Full activation orchestration, called from the macos-configure-finder-sidebar
# activation block.
finder_configure_sidebar() {
  local favorites_json="$1"
  local jq_bin="$2"
  local mysides_bin="$3"
  local expected_order="$4"
  local managed_count="$5"
  if [ ! -x "$mysides_bin" ]; then
    warn "mysides is unavailable; Finder favorites were not updated automatically."
    exit 0
  fi

  _finder_sidebar_failed=0

  finder_ensure_directories "$favorites_json" "$jq_bin"
  finder_reconcile_strict "$favorites_json" "$jq_bin" "$mysides_bin" || _finder_sidebar_failed=1

  # check-suppress:suppression_doc: mysides list may fail (segfault on corrupted bookmarks); best-effort probe.
  _finder_list_output=$("$mysides_bin" list 2>/dev/null || true)
  _finder_actual_order="$(echo "$_finder_list_output" | /usr/bin/awk -F' -> ' 'NF >= 1 && $1 != "" { print $1 }' | /usr/bin/head -n "$managed_count" | /usr/bin/paste -sd'|' -)"
  if [ "$_finder_actual_order" != "$expected_order" ]; then
    warn "mysides reported sidebar order mismatch (expected: $expected_order, actual: $_finder_actual_order)."
    _finder_sidebar_failed=1
  fi

  # check-suppress:suppression_doc: daemon may not be running; killall exits 1, activation must not abort.
  /usr/bin/killall sharedfilelistd 2>/dev/null || true
  # check-suppress:suppression_doc: see killall sharedfilelistd -- daemon may not be running.
  /usr/bin/killall -KILL cfprefsd 2>/dev/null || true

  if [ "$_finder_sidebar_failed" -eq 1 ]; then
    die "Finder favorites were partially updated; if stale entries persist, log out and log back in once."
  else
    say "Finder favorites updated automatically."
  fi
}
