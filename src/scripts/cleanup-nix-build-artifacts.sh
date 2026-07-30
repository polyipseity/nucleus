#!/usr/bin/env bash
# shellcheck shell=bash # uses process substitution and read -d for safe null-delimited find output
# Remove stale `result` and `result-*` symlinks left by `nix build`,
# `nix run ... -o result`, or `nixos-generators`.
#
# Only removes symlinks — real files or directories with these names are
# preserved (with a warning) since they cannot be `result` artifacts.
#
# Source from entry-point scripts after sourcing lib.sh.
#
# Options (read from $_cnba_options):
#   --dry-run  Print actions instead of executing them.
#
# Environment variables:
#   REPO_ROOT  Repository root (must be set before sourcing).

[ -n "${REPO_ROOT:-}" ] || {
  printf '%s\n' "cleanup-nix-build-artifacts: REPO_ROOT is not set" >&2
  return 1
}

_cnba_options="${_cnba_options:-}"
_cnba_dry_run=false
for _cnba_opt in $_cnba_options; do
  case "$_cnba_opt" in
    --dry-run) _cnba_dry_run=true ;;
    *) printf '%s\n' "cleanup-nix-build-artifacts: unknown option: $_cnba_opt" >&2; return 1 ;;
  esac
done

_cnba_found=false

# Recursively scan for result and result-* symlinks without following symlinks
# (find default behavior — no -L flag) to avoid traversing into Nix store or
# other large trees.
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
  find "$REPO_ROOT" \
    -path "$REPO_ROOT/.git" -prune -o \
    -path "$REPO_ROOT/.direnv" -prune -o \
    -path "$REPO_ROOT/vendor" -prune -o \  # ref: EXCLUDE-LISTS.md#B8 — reason: structural invariant
    \( -name result -o -name 'result-*' \) \
    -print0 2>/dev/null || true # check-suppress:suppression_doc: find returns non-zero when -prune skips dirs; || true prevents set -e abort
)

if $_cnba_dry_run && ! $_cnba_found; then
  say "no stale Nix build artifacts found."
fi
