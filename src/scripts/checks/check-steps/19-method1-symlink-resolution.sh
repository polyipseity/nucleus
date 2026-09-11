# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "method-one-symlink-resolution" "Method-1 symlinks resolve to live repo root" run_method1_symlink_resolution

# run_method1_symlink_resolution — Read-only verification that every deployed
# method-1 (writable) symlink points at the LIVE repo root, not a read-only
# /nix/store/*-source snapshot.
#
# Background: method-1 symlinks are created at activation time by
# src/scripts/configs/seed-writable-symlink.sh against the live repo root
# (derive_repo_root). The historical bug was baking `repoRoot = ../.` (a Nix path
# literal copied into a read-only /nix/store/*-source snapshot at eval time) as the
# symlink target via mkOutOfStoreSymlink — writes failed with EACCES (HTTP 500) and
# "repo changes take effect without rebuild" was false. This step catches any
# regression where a method-1 link resolves into the store instead of the live tree.
#
# Candidates come from the deployed manifest written by
# home.activation.write-method1-symlink-manifest (src/modules/home.nix, script
# src/scripts/configs/write-method1-symlink-manifest.sh). The step used to carry its
# own hand-maintained array, which had already drifted from the deployed set and
# covered none of the trees that held the 17 stale links — so the list is derived
# from the deployment instead of restated here, and there is deliberately no
# fallback list: a missing manifest means this host cannot be audited (skipped), not
# that the audit passed.
#
# Manifest entries are absolute paths: a symlink is inspected directly, a directory
# is walked one level for symlinks. Absent entries are skipped (an absent optional
# app directory is not a defect); the post-seeding existence contract lives in
# home.activation.verify-managed-symlink-paths.
#
# Read-only-safe: it only reads symlink targets and immutable flags; it never writes
# into the repo or the home. It skips (exit 2) when run outside a deployed host
# (no $HOME, no manifest, or nothing to inspect), so it is safe in CI.
run_method1_symlink_resolution() {
  local -n ctx="$1"
  local _has_args="${ctx[HAS_ARGS]}" _repo_root="${ctx[REPO_ROOT]}"
  shift

  # Path-scoped runs (check.sh given file args) don't apply — this inspects the
  # deployed home, not repo files. Skip to avoid false negatives.
  if $_has_args; then
    skip_step "$(step_number)" "Method-1 symlinks resolve to live repo root" "path-scoped run; inspects deployed home"
    return 2
  fi

  local _home="${HOME:-}"
  if [ -z "$_home" ] || [ ! -d "$_home" ]; then
    skip_step "$(step_number)" "Method-1 symlinks resolve to live repo root" "no \$HOME; not a deployed host"
    return 2
  fi

  # Resolve the live repo root the same way the activation helper does.
  local _live_root
  _live_root="$(derive_repo_root)" || {
    skip_step "$(step_number)" "Method-1 symlinks resolve to live repo root" "cannot resolve live repo root"
    return 2
  }

  local _manifest
  _manifest="$(derive_nucleus_user_root)/method1-symlink-manifest.txt"
  if [ ! -f "$_manifest" ]; then
    skip_step "$(step_number)" "Method-1 symlinks resolve to live repo root" "no deployed manifest at $_manifest; run nucleus-apply"
    return 2
  fi

  local _checked=0 _violations=0 _entry _origin _link _target
  local -a _links=()
  while IFS= read -r _entry; do
    # Manifest comments are the only skipped lines; every other line is a path and
    # an unparsable one is a violation, never a silent skip.
    case "$_entry" in
    '' | '#'*) continue ;;
    /*) ;;
    *)
      error "method-1 manifest entry '$_entry' is not an absolute path"
      _violations=$((_violations + 1))
      continue
      ;;
    esac

    _links=()
    if [ -L "$_entry" ]; then
      _links=("$_entry")
      _origin="explicit"
    elif [ -d "$_entry" ]; then
      _origin="walked"
      while IFS= read -r _link; do
        # The bundle-installed extension directory is not a repo deployment.
        [ "$_link" = "$_entry/extensions" ] && continue
        _links+=("$_link")
      done < <(find "$_entry" -mindepth 1 -maxdepth 1 -type l -print 2>/dev/null)
    else
      # Absent: an optional app directory, or a path that the post-seeding
      # existence check owns. Not this step's concern.
      continue
    fi

    for _link in "${_links[@]}"; do
      _target="$(readlink "$_link")"
      _checked=$((_checked + 1))
      case "$_target" in
      "$_live_root"/*)
        # Correct: resolves into the live repo tree.
        ;;
      /nix/store/*-source/*)
        error "method-1 symlink '$_link' resolves to read-only store snapshot: $_target"
        _violations=$((_violations + 1))
        ;;
      /nix/store/*)
        warn "method-1 symlink '$_link' resolves into the Nix store: $_target"
        ;;
      *)
        # A walked root legitimately contains activation-managed links that point
        # outside the repo (the nucleus root's `logs` and `state` links into the
        # conventional per-user directories), so only explicit entries are
        # reported: those are the ones declared as method-1 deployments.
        if [ "$_origin" = "explicit" ]; then
          warn "method-1 symlink '$_link' resolves outside live repo root: $_target"
        fi
        ;;
      esac
    done
  done <"$_manifest"

  if [ "$_checked" -eq 0 ]; then
    skip_step "$(step_number)" "Method-1 symlinks resolve to live repo root" "no deployed method-1 symlinks found among the manifest entries"
    return 2
  fi

  if [ "$_violations" -gt 0 ]; then
    error "$_violations method-1 symlink(s) resolve to a read-only store snapshot instead of the live repo root"
    return 1
  fi

  say "verified $_checked method-1 symlink(s) resolve to live repo root ($_live_root)"
  return 0
}
