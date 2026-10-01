#!/usr/bin/env bash
# shellcheck shell=bash # uses process substitution and read -d for safe null-delimited find output
# Remove stale `result` and `result-*` symlinks from `nix build`,
# `nix run ... -o result`, or `nixos-generators`. Real files and directories
# with these names are preserved, since they cannot be build artifacts.
#
# Sourced from entry points after lib.sh. Options come from
# $_cnba_options: --dry-run prints actions instead of executing them.
# REPO_ROOT must be set before sourcing.

[ -n "${REPO_ROOT:-}" ] || {
  error -l cleanup-nix-build-artifacts "REPO_ROOT is not set"
  return 1
}

_cnba_options="${_cnba_options:-}"
_cnba_dry_run=false
for _cnba_opt in $_cnba_options; do
  case "$_cnba_opt" in
  --dry-run) _cnba_dry_run=true ;;
  *)
    error -l cleanup-nix-build-artifacts "unknown option: $_cnba_opt"
    return 1
    ;;
  esac
done

_cnba_found=false

# find without -L, so the scan never traverses into the store.
while IFS= read -r -d '' _cnba_path; do
  if [ -L "$_cnba_path" ]; then
    _cnba_target="$(readlink "$_cnba_path")"
    if $_cnba_dry_run; then
      dry_run "would remove stale Nix build symlink: $_cnba_path -> $_cnba_target"
      dry_run "  how it was created: 'nix build' or 'nix build -o result' at the repo root. Run 'nucleus-cleanup-nix' or 'rm $_cnba_path' to remove."
    else
      rm "$_cnba_path"
      say "removed stale Nix build symlink: $_cnba_path -> $_cnba_target"
    fi
    _cnba_found=true
  else
    warn "found non-symlink at $_cnba_path — skipping (not a Nix build artifact)"
  fi
done < <(
  # WHY: prune the structural directories for speed. File-processing scripts
  # use deny-list.sh's filter_gitignored instead.
  # ref: allow-and-deny-lists.instructions.md#B8 -- structural invariant
  find "$REPO_ROOT" \
    -path "$REPO_ROOT/.git" -prune -o \
    -path "$REPO_ROOT/.direnv" -prune -o \
    -path "$REPO_ROOT/vendor" -prune -o \
    \( -name result -o -name 'result-*' \) \
    -print0 2>/dev/null || true # check-suppress:suppression_doc: find returns non-zero when -prune skips dirs; || true prevents set -e abort
)

if $_cnba_dry_run && ! $_cnba_found; then
  say "no stale Nix build artifacts found."
fi
