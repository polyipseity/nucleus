# shellcheck shell=sh
# Shared symlink convergence functions for managing directory-based symlink
# collections.  Assumes _nucleus_{un,}protect_symlink from
# symlink-hardening.sh are available at call sites.
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
  # shellcheck disable=SC2086 # reason: $_ncs_find_type is a space-separated find type flag list, word splitting intentional
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

# _nucleus_converge_overlay_entry SOURCE_PATH TARGET_LINK LABEL CONFLICT_TEST \
#   CONFLICT_MSG_SUFFIX
#
# Symlinks one overlay-resolved first-level config entry (file or directory)
# into TARGET_LINK. Requires resolve-user-config.sh at the call site when using
# merged iteration helpers below.
_nucleus_converge_overlay_entry() {
  _coe_source="$1"
  _coe_link="$2"
  _coe_label="$3"
  _coe_conflict_test="$4"
  _coe_conflict_msg_suffix="$5"
  if [ -L "$_coe_link" ]; then
    if [ "$(readlink "$_coe_link")" = "$_coe_source" ]; then
      return 0
    fi
    _nucleus_unprotect_symlink "$_coe_label" "$_coe_link"
    rm "$_coe_link"
    ln -s "$_coe_source" "$_coe_link"
    _nucleus_protect_symlink "$_coe_label" "$_coe_link"
    echo "$_coe_label: updated $_coe_link -> $_coe_source"
  elif test "$_coe_conflict_test" "$_coe_link"; then
    echo "$_coe_label: $_coe_link $_coe_conflict_msg_suffix" >&2
    exit 1
  else
    ln -s "$_coe_source" "$_coe_link"
    _nucleus_protect_symlink "$_coe_label" "$_coe_link"
    echo "$_coe_label: linked $_coe_link -> $_coe_source"
  fi
}

# _nucleus_converge_merged_config_symlinks USERNAME CONFIG_NAME REPO_ROOT \
#   TARGET_DIR LABEL FIND_TYPE CONFLICT_TEST CONFLICT_MSG_SUFFIX [SKIP_NAMES]
#
# Converges first-level merged overlay entries into TARGET_DIR. Skips SKIP_NAMES.
# Requires resolve-user-config.sh to be sourced before symlink-convergence.sh.
_nucleus_converge_merged_config_symlinks() {
  _cmc_username="$1"
  _cmc_config_name="$2"
  _cmc_repo_root="$3"
  _cmc_target="$4"
  _cmc_label="$5"
  _cmc_find_type="$6"
  _cmc_conflict_test="$7"
  _cmc_conflict_msg_suffix="$8"
  _cmc_skips="${9:-}"
  export NUCLEUS_REPO_ROOT="$_cmc_repo_root"
  while IFS= read -r _cmc_entry_name; do
    [ -n "$_cmc_entry_name" ] || continue
    for _cmc_skip in $_cmc_skips; do
      [ "$_cmc_entry_name" = "$_cmc_skip" ] && continue 2
    done
    _cmc_source="$(resolve_user_config_first_level_entry "$_cmc_username" "$_cmc_config_name" "$_cmc_entry_name")"
    if [ -n "$_cmc_find_type" ] && [ ! -d "$_cmc_source" ]; then
      continue
    fi
    if [ -z "$_cmc_find_type" ] || [ -d "$_cmc_source" ]; then
      _nucleus_converge_overlay_entry \
        "$_cmc_source" "$_cmc_target/$_cmc_entry_name" "$_cmc_label" \
        "$_cmc_conflict_test" "$_cmc_conflict_msg_suffix"
    fi
  done <<EOF
$(list_user_config_first_level_entries "$_cmc_username" "$_cmc_config_name")
EOF
}

# _nucleus_remove_stale_merged_symlinks TARGET_DIR USERNAME CONFIG_NAME LABEL [SKIP_NAMES]
_nucleus_remove_stale_merged_symlinks() {
  _rsm_target="$1"
  _rsm_username="$2"
  _rsm_config_name="$3"
  _rsm_repo_root="$4"
  _rsm_label="$5"
  _rsm_skips="${6:-}"
  export NUCLEUS_REPO_ROOT="$_rsm_repo_root"
  find "$_rsm_target" -mindepth 1 -maxdepth 1 -type l | while IFS= read -r _rsm_candidate; do
    _rsm_cname="$(basename "$_rsm_candidate")"
    for _rsm_skip in $_rsm_skips; do
      [ "$_rsm_cname" = "$_rsm_skip" ] && continue 2
    done
    _rsm_ctarget="$(readlink "$_rsm_candidate")"
    # check-suppress:suppression_doc: registry lookup may fail for unmanaged child names; empty expected skips stale cleanup.
    _rsm_expected="$(resolve_user_config_first_level_entry "$_rsm_username" "$_rsm_config_name" "$_rsm_cname" 2>/dev/null || true)"
    if [ -n "$_rsm_expected" ] && [ "$_rsm_ctarget" = "$_rsm_expected" ]; then
      if [ ! -e "$_rsm_ctarget" ] && [ ! -L "$_rsm_ctarget" ]; then
        _nucleus_unprotect_symlink "$_rsm_label" "$_rsm_candidate"
        rm "$_rsm_candidate"
        echo "$_rsm_label: removed stale symlink for $_rsm_cname (source removed)"
      fi
    fi
  done
}
