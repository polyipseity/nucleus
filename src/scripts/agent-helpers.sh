# shellcheck shell=sh
# src/scripts/agent-helpers.sh — Shared shell functions for agent activation entries.
#
# Source this file (conceptually; in Nix it is inlined via builtins.readFile) to
# make the following functions available in home-manager activation scripts.
#
# Provided functions:
#   _nucleus_protect_symlink       — set uchg / chattr +i on a symlink
#   _nucleus_unprotect_symlink     — clear uchg / chattr -i from a symlink
#   _nucleus_resolve_repo_root     — resolve $NUCLEUS_REPO, fail if unset
#   _nucleus_prepend_first_executable_dir — prepend dir containing executable to PATH

# ---------------------------------------------------------------------------
# Symlink protection helpers (macOS / Linux)
# ---------------------------------------------------------------------------
# Set/clear immutable flags on symlinks so managed agent config symlinks are
# not accidentally removed or replaced outside of an apply run.

_nucleus_protect_symlink() {
  _nps_context="$1"
  _nps_path="$2"
  case "$(uname -s)" in
    Darwin)
      if ! /usr/bin/chflags -h uchg "$_nps_path"; then
        echo "$_nps_context: warning — could not protect symlink $_nps_path with uchg." >&2
      fi
      ;;
    Linux)
      if command -v chattr >/dev/null; then
        if ! chattr -h +i "$_nps_path"; then
          echo "$_nps_context: warning — could not protect symlink $_nps_path with chattr +i." >&2
        fi
      fi
      ;;
  esac
}

_nucleus_unprotect_symlink() {
  _nus_context="$1"
  _nus_path="$2"
  case "$(uname -s)" in
    Darwin)
      if ! /usr/bin/chflags -h nouchg "$_nus_path"; then
        echo "$_nus_context: warning — could not clear uchg from symlink $_nus_path before update." >&2
      fi
      ;;
    Linux)
      if command -v chattr >/dev/null; then
        if ! chattr -h -i "$_nus_path"; then
          echo "$_nus_context: warning — could not clear chattr +i from symlink $_nus_path before update." >&2
        fi
      fi
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Repo root resolver
# ---------------------------------------------------------------------------
# Resolve the active repo root from $NUCLEUS_REPO (set by apply.sh) or an
# optional fallback path baked in at eval time.  The fallback is a static
# path captured during Nix evaluation (where NUCLEUS_REPO is available) and
# embedded into the activation script so home-manager activation, which runs
# as the user and does not inherit the sudo-level env var, can still find the
# repo root.
#
# Arguments:
#   $1  Context label for diagnostics.
#   $2  Optional fallback path (baked in at eval time).
_nucleus_resolve_repo_root() {
  _nrr_context="$1"
  _nrr_fallback="${2:-}"
  if [ -n "${NUCLEUS_REPO:-}" ]; then
    printf '%s\n' "$NUCLEUS_REPO"
  elif [ -n "$_nrr_fallback" ] && [ -d "$_nrr_fallback" ]; then
    printf '%s\n' "$_nrr_fallback"
  else
    echo "$_nrr_context: repo root not set; run via apply.sh or export NUCLEUS_REPO." >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# PATH-probing helper
# ---------------------------------------------------------------------------
# Prepend the first directory that contains a given executable to PATH.
_nucleus_prepend_first_executable_dir() {
  _nped_executable="$1"
  shift
  for _nped_dir in "$@"; do
    if [ -x "$_nped_dir/$_nped_executable" ]; then
      PATH="$_nped_dir:$PATH"
      export PATH
      return 0
    fi
  done
  return 1
}
