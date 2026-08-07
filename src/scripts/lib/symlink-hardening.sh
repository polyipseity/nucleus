# shellcheck shell=sh
# Source this file (conceptually; in Nix it is inlined via builtins.readFile) to
# make the following functions available in home-manager activation scripts.
#
# Provided functions:
#   _nucleus_protect_symlink       — set uchg / chattr +i on a symlink
#   _nucleus_unprotect_symlink     — clear uchg / chattr -i from a symlink
#   _nucleus_resolve_repo_root     — resolve $NUCLEUS_REPO_ROOT, fail if unset
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

# Resolve $NUCLEUS_REPO_ROOT or fallback path baked in at eval time.
# home-manager activation runs as the user and does not inherit NUCLEUS_REPO_ROOT,
# so the fallback is embedded into the activation script during Nix eval.
#
# Arguments:
#   $1  Context label for diagnostics.
#   $2  Optional fallback path (baked in at Nix eval time).
_nucleus_resolve_repo_root() {
  _nrr_context="$1"
  _nrr_fallback="${2:-}"
  if [ -n "${NUCLEUS_REPO_ROOT:-}" ]; then
    # Resolve symlinks so downstream symlink creation (dev-repos.nix) does not
    # self-loop when NUCLEUS_REPO_ROOT points at a symlink.
    # check-suppress:suppression_doc: fallback path may not be valid; cd/pwd probe expected to fail.
    NUCLEUS_REPO_ROOT="$(CDPATH='' cd -- "$NUCLEUS_REPO_ROOT" && pwd -P 2>/dev/null)" || true
    printf '%s\n' "$NUCLEUS_REPO_ROOT"
  elif [ -n "$_nrr_fallback" ] && [ -d "$_nrr_fallback" ]; then
    # Also resolve fallback path for the same self-loop prevention.
    # check-suppress:suppression_doc: fallback path may not be valid; cd/pwd probe expected to fail.
    _nrr_resolved="$(CDPATH='' cd -- "$_nrr_fallback" && pwd -P 2>/dev/null)" || true
    printf '%s\n' "${_nrr_resolved:-$_nrr_fallback}"
  else
    echo "$_nrr_context: repo root not set; run via apply.sh or export NUCLEUS_REPO_ROOT." >&2
    return 1
  fi
}

# ensure_file_symlink TARGET LINK
# Creates LINK as a symlink pointing to TARGET (a file).
ensure_file_symlink() {
  _efs_target="$1"
  _efs_link="$2"

  if [ -L "$_efs_link" ]; then
    [ "$(readlink "$_efs_link")" = "$_efs_target" ] && return 0
    _nucleus_unprotect_symlink "VS Code" "$_efs_link"
    rm "$_efs_link"
  elif [ -e "$_efs_link" ]; then
    echo "ensure_file_symlink: $_efs_link exists and is not a symlink to $_efs_target; fix manually and re-apply" >&2
    return 1
  fi

  mkdir -p "$(dirname "$_efs_link")"
  ln -s "$_efs_target" "$_efs_link"
  _nucleus_protect_symlink "VS Code" "$_efs_link"
}

# ensure_dir_symlink TARGET LINK
# Creates LINK as a symlink pointing to TARGET (a directory).
ensure_dir_symlink() {
  _eds_target="$1"
  _eds_link="$2"

  if [ -L "$_eds_link" ]; then
    [ "$(readlink "$_eds_link")" = "$_eds_target" ] && return 0
    _nucleus_unprotect_symlink "VS Code" "$_eds_link"
    rm "$_eds_link"
  elif [ -e "$_eds_link" ]; then
    echo "ensure_dir_symlink: $_eds_link exists and is not a symlink to $_eds_target; fix manually and re-apply" >&2
    return 1
  fi

  mkdir -p "$(dirname "$_eds_link")"
  ln -s "$_eds_target" "$_eds_link"
  _nucleus_protect_symlink "VS Code" "$_eds_link"
}
