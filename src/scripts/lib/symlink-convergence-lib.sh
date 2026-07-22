# shellcheck shell=sh
# Shared symlink convergence functions for managing directory-based symlink
# collections.  Assumes _nucleus_{un,}protect_symlink from
# symlink-hardening-lib.sh are available at call sites.
#
# Provided functions:
#   _nucleus_remove_stale_symlinks
#   _nucleus_converge_symlinks

# _nucleus_remove_stale_symlinks TARGET_DIR SOURCE_PREFIX LABEL [SKIP_NAMES]
#
# Removes symlinks from TARGET_DIR whose targets start with SOURCE_PREFIX but
# whose target no longer exists (neither as a regular file/dir nor as a broken
# symlink — the latter is excluded because the link may still be intentional).
# SKIP_NAMES is a space-separated list of basenames to leave untouched.
_nucleus_remove_stale_symlinks() {
  _nrs_target="$1"
  _nrs_source="$2"
  _nrs_label="$3"
  _nrs_skips="${4:-}"
  find "$_nrs_target" -mindepth 1 -maxdepth 1 -type l | while IFS= read -r _nrs_candidate; do
    _nrs_cname="$(basename "$_nrs_candidate")"
    for _nrs_skip in $_nrs_skips; do
      [ "$_nrs_cname" = "$_nrs_skip" ] && continue 2
    done
    _nrs_ctarget="$(readlink "$_nrs_candidate")"
    case "$_nrs_ctarget" in
      "$_nrs_source"/*)
        if [ ! -e "$_nrs_ctarget" ] && [ ! -L "$_nrs_ctarget" ]; then
          _nucleus_unprotect_symlink "$_nrs_label" "$_nrs_candidate"
          rm "$_nrs_candidate"
          echo "$_nrs_label: removed stale symlink for $_nrs_cname (source removed)"
        fi
        ;;
    esac
  done
}

# _nucleus_converge_symlinks SOURCE_DIR TARGET_DIR LABEL FIND_TYPE \
#   CONFLICT_TEST CONFLICT_MSG_SUFFIX [SKIP_NAMES]
#
# Creates or updates symlinks in TARGET_DIR for each entry in SOURCE_DIR.
# FIND_TYPE is a find(1) type qualifier (e.g. "-type d") or "" for all entry
# types.  CONFLICT_TEST is a test(1) operator (e.g. "-d" or "-e") applied to
# the target path when it exists as a non-symlink.  On conflict the message
# "LABEL: LINK_PATH CONFLICT_MSG_SUFFIX" is printed before exit(1).
# SKIP_NAMES is a space-separated list of basenames to skip.
_nucleus_converge_symlinks() {
  _ncs_source="$1"
  _ncs_target="$2"
  _ncs_label="$3"
  _ncs_find_type="$4"
  _ncs_conflict_test="$5"
  _ncs_conflict_msg_suffix="$6"
  _ncs_skips="${7:-}"
  # shellcheck disable=SC2086 # $_ncs_find_type is a space-separated find type flag list, word splitting intentional
  find "$_ncs_source" -mindepth 1 -maxdepth 1 $_ncs_find_type | while IFS= read -r _ncs_entry; do
    _ncs_name="$(basename "$_ncs_entry")"
    for _ncs_skip in $_ncs_skips; do
      [ "$_ncs_name" = "$_ncs_skip" ] && continue 2
    done
    _ncs_link="$_ncs_target/$_ncs_name"
    if [ -L "$_ncs_link" ]; then
      if [ "$(readlink "$_ncs_link")" = "$_ncs_entry" ]; then
        continue
      fi
      _nucleus_unprotect_symlink "$_ncs_label" "$_ncs_link"
      rm "$_ncs_link"
      ln -s "$_ncs_entry" "$_ncs_link"
      _nucleus_protect_symlink "$_ncs_label" "$_ncs_link"
      echo "$_ncs_label: updated $_ncs_target/$_ncs_name -> $_ncs_entry"
    elif test "$_ncs_conflict_test" "$_ncs_link"; then
      echo "$_ncs_label: $_ncs_link $_ncs_conflict_msg_suffix" >&2
      exit 1
    else
      ln -s "$_ncs_entry" "$_ncs_link"
      _nucleus_protect_symlink "$_ncs_label" "$_ncs_link"
      echo "$_ncs_label: linked $_ncs_target/$_ncs_name -> $_ncs_entry"
    fi
  done
}
