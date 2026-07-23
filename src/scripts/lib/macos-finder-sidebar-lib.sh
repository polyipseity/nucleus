#!/usr/bin/env bash
# Finder sidebar favorites library functions.
#
# All functions take their required data as function parameters. The caller
# (activation script) passes Nix-derived values.

# ---------------------------------------------------------------------------
# Ensure directories referenced by managed Finder favorites exist.
# System-owned directories (~/Desktop, ~/Downloads, etc.) are created
# unconditionally; managed favorites use a symlink-safe guard.
# ---------------------------------------------------------------------------
finder_ensure_directories() {
  local favorites_json="$1"
  local jq_bin="$2"
  _ensure_tmp=$(mktemp)
  printf '%s\n' "$favorites_json" | "$jq_bin" -r '.[] | .name' > "$_ensure_tmp"
  while IFS= read -r _name; do
    # System-owned favorites (Applications, Desktop, Documents, Downloads,
    # Music, Movies, Pictures) always exist; managed favorites may be
    # symlinks and must not be overwritten.
    case "$_name" in
      Applications|Desktop|Documents|Downloads|Music|Movies|Pictures)
        mkdir -p "$HOME/$_name"
        ;;
      *)
        if [ ! -d "$HOME/$_name" ] && [ ! -L "$HOME/$_name" ]; then
          mkdir -p "$HOME/$_name"
        fi
        ;;
    esac
  done < "$_ensure_tmp"
  rm -f "$_ensure_tmp"
  unset _ensure_tmp
}

# ---------------------------------------------------------------------------
# Pre-remove managed favorites and default extras by name.
# Removes known favorites + default sidebar entries ("/", user home alias,
# ".Trash") that reappear after daemon restarts.
# Soft-fail (|| true) because mysides is known to segfault on corrupted
# bookmarks — activation must not abort.
# ---------------------------------------------------------------------------
finder_pre_remove() {
  local favorites_json="$1"
  local jq_bin="$2"
  local mysides_bin="$3"
  _pr_tmp=$(mktemp)
  printf '%s\n' "$favorites_json" | "$jq_bin" -r '.[] | .name' > "$_pr_tmp"
  while IFS= read -r _name; do
    # check-suppress:suppression_doc: mysides is known to segfault on corrupted bookmarks; soft-fail prevents activation abort.
    "$mysides_bin" remove "$_name" >/dev/null 2>&1 || true
  done < "$_pr_tmp"
  rm -f "$_pr_tmp"
  # Default extras that reappear after daemon restarts
  # check-suppress:suppression_doc: see finder_pre_remove — mysides segfaults.
  "$mysides_bin" remove "/" >/dev/null 2>&1 || true
  # check-suppress:suppression_doc: see finder_pre_remove.
  "$mysides_bin" remove "$(id -un)" >/dev/null 2>&1 || true
  # check-suppress:suppression_doc: see finder_pre_remove.
  "$mysides_bin" remove ".Trash" >/dev/null 2>&1 || true
  unset _pr_tmp
}

# ---------------------------------------------------------------------------
# Clear all current sidebar favorites by iterating over `mysides list`
# output. Uses a temp file to avoid subshell isolation (while-read in
# pipelines creates a subshell in POSIX sh).
# ---------------------------------------------------------------------------
finder_clear_all() {
  local mysides_bin="$1"
  _clear_tmp=$(mktemp)
  # check-suppress:suppression_doc: mysides list may segfault on corrupted bookmarks; soft-fail prevents activation abort.
  "$mysides_bin" list 2>/dev/null > "$_clear_tmp" || true
  while IFS= read -r _line; do
    _name="${_line%% -> *}"
    [ -n "$_name" ] || continue
    # check-suppress:suppression_doc: mysides remove may segfault; soft-fail prevents activation abort.
    "$mysides_bin" remove "$_name" >/dev/null 2>&1 || true
  done < "$_clear_tmp"
  rm -f "$_clear_tmp"
  unset _clear_tmp
}

# ---------------------------------------------------------------------------
# Add managed favorites (strict mode).
# Each favorite addition logs a failure message to stderr on error.
# Returns 1 if any addition fails (caller must decide how to propagate).
# ---------------------------------------------------------------------------
finder_add_managed_strict() {
  local favorites_json="$1"
  local jq_bin="$2"
  local mysides_bin="$3"
  _add_tmp=$(mktemp)
  printf '%s\n' "$favorites_json" | "$jq_bin" -r '.[] | @base64' > "$_add_tmp"
  _add_failed=0
  while IFS= read -r _item; do
    _jq() { printf '%s\n' "$_item" | base64 -d | "$jq_bin" -r "$1"; }
    _name=$(_jq '.name')
    _url=$(_jq '.url')
    if ! "$mysides_bin" add "$_name" "$_url" >/dev/null 2>&1; then
      echo "macos: failed to add Finder favorite '$_name' ($_url)." >&2
      _add_failed=1
    fi
  done < "$_add_tmp"
  rm -f "$_add_tmp"
  unset _add_tmp _jq
  return "$_add_failed"
}

# ---------------------------------------------------------------------------
# Add managed favorites (best-effort mode).
# Failures are silently ignored — used after Finder desktop restart to
# restore favorites without aborting if mysides encounters transient errors.
# ---------------------------------------------------------------------------
finder_add_managed_best_effort() {
  local favorites_json="$1"
  local jq_bin="$2"
  local mysides_bin="$3"
  _add_tmp=$(mktemp)
  printf '%s\n' "$favorites_json" | "$jq_bin" -r '.[] | @base64' > "$_add_tmp"
  while IFS= read -r _item; do
    _jq() { printf '%s\n' "$_item" | base64 -d | "$jq_bin" -r "$1"; }
    _name=$(_jq '.name')
    _url=$(_jq '.url')
    # check-suppress:suppression_doc: mysides add may segfault; best-effort add must not abort activation.
    "$mysides_bin" add "$_name" "$_url" >/dev/null 2>&1 || true
  done < "$_add_tmp"
  rm -f "$_add_tmp"
  unset _add_tmp _jq
}

# ---------------------------------------------------------------------------
# Remove default extras that reappear after daemon restarts.
# ---------------------------------------------------------------------------
finder_remove_default_extras() {
  local mysides_bin="$1"
  # check-suppress:suppression_doc: mysides is known to segfault on corrupted bookmarks; soft-fail prevents activation abort.
  "$mysides_bin" remove "/" >/dev/null 2>&1 || true
  # check-suppress:suppression_doc: see finder_remove_default_extras — mysides segfaults.
  "$mysides_bin" remove "$(id -un)" >/dev/null 2>&1 || true
  # check-suppress:suppression_doc: see finder_remove_default_extras.
  "$mysides_bin" remove ".Trash" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Full sidebar reconciliation.
# ---------------------------------------------------------------------------

# Strict mode — used during initial activation.
# Returns 1 if any favorite addition failed (caller propagates to
# _finder_sidebar_failed).
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

# Best-effort mode — used after Finder desktop restart to restore favorites
# without aborting if mysides encounters transient errors.
finder_reconcile_best_effort() {
  local favorites_json="$1"
  local jq_bin="$2"
  local mysides_bin="$3"
  finder_pre_remove "$favorites_json" "$jq_bin" "$mysides_bin"
  finder_clear_all "$mysides_bin"
  finder_add_managed_best_effort "$favorites_json" "$jq_bin" "$mysides_bin"
  finder_remove_default_extras "$mysides_bin"
}

# ---------------------------------------------------------------------------
# Full Finder sidebar activation orchestration.
# Called from configureFinderSidebar activation block.
# ---------------------------------------------------------------------------
finder_configure_sidebar() {
  local favorites_json="$1"
  local jq_bin="$2"
  local mysides_bin="$3"
  local expected_order="$4"
  local managed_count="$5"
  if [ ! -x "$mysides_bin" ]; then
    echo "macos: mysides is unavailable; Finder favorites were not updated automatically." >&2
    exit 0
  fi

  _finder_sidebar_failed=0

  finder_ensure_directories "$favorites_json" "$jq_bin"
  finder_reconcile_strict "$favorites_json" "$jq_bin" "$mysides_bin" || _finder_sidebar_failed=1

  # check-suppress:suppression_doc: mysides list may fail (segfault on corrupted bookmarks); best-effort probe.
  _finder_list_output=$("$mysides_bin" list 2>/dev/null || true)
  _finder_actual_order="$(echo "$_finder_list_output" | /usr/bin/awk -F' -> ' 'NF >= 1 && $1 != "" { print $1 }' | /usr/bin/head -n "$managed_count" | /usr/bin/paste -sd'|' -)"
  if [ "$_finder_actual_order" != "$expected_order" ]; then
    echo "macos: warning — mysides reported sidebar order mismatch (expected: $expected_order, actual: $_finder_actual_order)." >&2
    _finder_sidebar_failed=1
  fi

  # Refresh finder-related daemons in-session
  # check-suppress:suppression_doc: daemon may not be running; killall exits 1, activation must not abort.
  /usr/bin/killall sharedfilelistd 2>/dev/null || true
  # check-suppress:suppression_doc: see killall sharedfilelistd — daemon may not be running.
  /usr/bin/killall -KILL cfprefsd 2>/dev/null || true

  if [ "$_finder_sidebar_failed" -eq 1 ]; then
    echo "macos: Finder favorites were partially updated; if stale entries persist, log out and log back in once." >&2
  else
    echo "macos: Finder favorites updated automatically." >&2
  fi
}
