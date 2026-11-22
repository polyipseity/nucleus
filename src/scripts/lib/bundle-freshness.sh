# shellcheck shell=sh
# Bundle freshness: tell the operator when the running bundle predates the tree.
#
# WHY this exists: nucleus-check and nucleus-test are Nix store bundles built at
# apply time. Running one against a newer working tree reports the deployed code,
# not the tree, so a policy violation already fixed at HEAD reads as a live
# failure. nucleus-apply already records the revision it deployed in its apply
# history, so this lib reads that record rather than adding a second mechanism.
[ -n "${_NUCLEUS_BUNDLE_FRESHNESS_SOURCED-}" ] && return
_NUCLEUS_BUNDLE_FRESHNESS_SOURCED=1

# _bundle_freshness_applied_rev: newest successful apply's commit hash, or empty.
# Reads the stub seam first so a test can drive it without a host. A set stub
# (even empty) is authoritative, so the "no history" case can be simulated.
_bundle_freshness_applied_rev() {
  if [ "${_bf_stub_applied_rev+x}" = "x" ]; then
    printf '%s\n' "$_bf_stub_applied_rev"
    return 0
  fi
  if ! command -v apply_history_read_all_entries >/dev/null 2>&1; then
    return 0
  fi
  _bf_applied_hist_path="$(apply_history_path)" || return 0
  [ -f "$_bf_applied_hist_path" ] || return 0
  # Newest success wins: a later failed apply deployed nothing.
  apply_history_read_all_entries 2>/dev/null | # check-suppress:suppression_doc: corrupt/unreadable history must not fail the pipeline
    jq -s -r '[.[] | select(.result == "success")] | last | .commitHash // empty' 2>/dev/null || true # check-suppress:suppression_doc: parse failure must not fail the pipeline
}

# _bundle_freshness_head_rev: the working tree's short HEAD, or empty. Resolved
# through derive_repo_root, never from the bundle's own location: the bundle lives in
# the Nix store, which is not a git repository, so anchoring here is what makes the
# comparison meaningful when the bundle runs. A set stub (even empty) is
# authoritative.
_bundle_freshness_head_rev() {
  if [ "${_bf_stub_head_rev+x}" = "x" ]; then
    printf '%s\n' "$_bf_stub_head_rev"
    return 0
  fi
  _bf_head_repo_root="$(derive_repo_root 2>/dev/null)" || return 0
  [ -n "$_bf_head_repo_root" ] || return 0
  git -C "$_bf_head_repo_root" rev-parse --short HEAD 2>/dev/null || true # check-suppress:suppression_doc: missing git/repo/HEAD must not fail the pipeline
}

# warn_if_bundle_predates_tree: one notice when the revision the newest successful
# apply deployed differs from the tree's HEAD. Never fails the caller: this is
# advice, and a missing history or a missing git must not turn a passing pipeline
# into a failing one.
warn_if_bundle_predates_tree() {
  [ -n "${_NUCLEUS_BUNDLE_FRESHNESS_NOTICED-}" ] && return 0
  # WHY _bf_warn_*: sourced-library scratch globals (no `local` in # shellcheck shell=sh).
  _bf_warn_applied="$(_bundle_freshness_applied_rev)"
  if [ -z "$_bf_warn_applied" ]; then
    return 0
  fi
  _bf_warn_head="$(_bundle_freshness_head_rev)"
  if [ -z "$_bf_warn_head" ]; then
    return 0
  fi
  if [ "$_bf_warn_applied" = "$_bf_warn_head" ]; then
    return 0
  fi
  notice "this bundle was built by an apply at ${_bf_warn_applied}, but the tree is at ${_bf_warn_head} (${_bf_warn_applied} is older). Run nucleus-apply to test what is in the tree."
  _NUCLEUS_BUNDLE_FRESHNESS_NOTICED=1
  return 0
}
