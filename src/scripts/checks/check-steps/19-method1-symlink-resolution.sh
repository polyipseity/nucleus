#!/usr/bin/env bash
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
# Read-only-safe: it only reads symlink targets and immutable flags; it never writes
# into the repo or the home. It skips (exit 2) when run outside a deployed host
# (no $HOME or the expected method-1 targets are absent), so it is safe in CI.
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

  # Candidate method-1 targets (relative to $HOME). Mirrors managedSymlinkPaths +
  # the per-user configs wired through seed-writable-symlink.sh.
  local _candidates=(
    ".config/camilladsp/configs"
    ".config/camillagui-backend/config.yml"
    ".config/discord-music-rpc/config.yaml"
    ".config/starship.toml"
    ".config/git/ignore"
    ".gitconfig"
    ".config/nextest/config.toml"
    ".config/direnv/direnvrc"
    ".config/direnv/lib/apple-sdk-override.sh"
    ".bunfig.toml"
    ".config/powershell/PSScriptAnalyzerSettings.psd1"
    ".config/uv/uv.toml"
  )

  local _checked=0 _violations=0 _target _resolved _candidate
  for _candidate in "${_candidates[@]}"; do
    _target="$_home/$_candidate"
    [ -e "$_target" ] || [ -L "$_target" ] || continue
    # Only inspect symlinks (method-1 links are symlinks; non-symlink files are
    # method-2/3 deployments and out of scope here).
    [ -L "$_target" ] || continue
    _resolved="$(readlink "$_target")"
    _checked=$((_checked + 1))
    case "$_resolved" in
    "$_live_root"/*)
      # Correct: resolves into the live repo tree.
      ;;
    /nix/store/*-source/*)
      error "method-1 symlink '$_target' resolves to read-only store snapshot: $_resolved"
      _violations=$((_violations + 1))
      ;;
    *)
      # Not the live root and not a known store snapshot. This is suspicious but
      # may be a legitimate non-repo target (e.g. a different absolute path); warn
      # rather than hard-fail to avoid false positives across host variations.
      warn "method-1 symlink '$_target' resolves outside live repo root: $_resolved"
      ;;
    esac
  done

  if [ "$_checked" -eq 0 ]; then
    skip_step "$(step_number)" "Method-1 symlinks resolve to live repo root" "no deployed method-1 symlinks found in \$HOME"
    return 2
  fi

  if [ "$_violations" -gt 0 ]; then
    error "$_violations method-1 symlink(s) resolve to a read-only store snapshot instead of the live repo root"
    return 1
  fi

  say "verified $_checked method-1 symlink(s) resolve to live repo root ($_live_root)"
  return 0
}
