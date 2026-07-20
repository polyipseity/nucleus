# shellcheck shell=sh
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

for _cnba_pattern in result result-*; do
  for _cnba_path in "$REPO_ROOT"/$_cnba_pattern; do
    [ -e "$_cnba_path" ] || [ -L "$_cnba_path" ] || continue
    if [ -L "$_cnba_path" ]; then
      _cnba_target="$(readlink "$_cnba_path")"
      if $_cnba_dry_run; then
        dry_run "would remove stale Nix build symlink: $_cnba_path -> $_cnba_target"
      else
        rm "$_cnba_path"
        say "removed stale Nix build symlink: $_cnba_path -> $_cnba_target"
      fi
      _cnba_found=true
    else
      warn "found non-symlink at $_cnba_path — skipping (not a Nix build artifact)"
    fi
  done
done

if $_cnba_dry_run && ! $_cnba_found; then
  say "no stale Nix build artifacts found."
fi
