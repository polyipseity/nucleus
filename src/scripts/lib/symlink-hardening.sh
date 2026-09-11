# shellcheck shell=sh
# Source this file (conceptually; in Nix it is inlined via builtins.readFile) to
# make the following functions available in home-manager activation scripts.
#
# Provided functions:
#   _nucleus_protect_symlink       — set uchg / chattr +i on a symlink
#   _nucleus_unprotect_symlink     — clear uchg / chattr -i from a symlink
#   _nucleus_symlink_error         — emit the F1 error line for a failed flag change
# Set/clear immutable flags on symlinks so managed agent config symlinks are
# not accidentally removed or replaced outside of an apply run.

# WHY: a flag change that genuinely fails is an error, not a warning, and an
# absent path is not a failure at all — several managed symlinks are created by
# the post-linkGeneration seeders, so unprotect/protect legitimately run before
# they exist.  Failures return non-zero instead of exiting here because this
# library is inlined into activation blocks via builtins.readFile and is sourced
# by scripts that do not all provide `die`; every caller runs under `set -e`,
# so the non-zero return aborts the activation.
_nucleus_symlink_error() {
  _nse_context="$1"
  _nse_message="$2"
  _nse_output="$3"
  if [ -n "$_nse_output" ]; then
    _nse_message="$_nse_message: $_nse_output"
  fi
  echo "$_nse_context: error: $_nse_message" >&2
  return 1
}

_nucleus_protect_symlink() {
  _nps_context="$1"
  _nps_path="$2"
  if [ ! -e "$_nps_path" ] && [ ! -L "$_nps_path" ]; then
    return 0
  fi
  _nps_err=""
  case "$(uname -s)" in
  Darwin)
    if ! _nps_err="$(/usr/bin/chflags -h uchg "$_nps_path" 2>&1)"; then
      _nucleus_symlink_error "$_nps_context" "could not protect symlink $_nps_path with uchg" "$_nps_err"
      return 1
    fi
    ;;
  Linux)
    if command -v chattr >/dev/null; then
      if ! _nps_err="$(chattr -h +i "$_nps_path" 2>&1)"; then
        _nucleus_symlink_error "$_nps_context" "could not protect symlink $_nps_path with chattr +i" "$_nps_err"
        return 1
      fi
    fi
    ;;
  esac
}

_nucleus_unprotect_symlink() {
  _nus_context="$1"
  _nus_path="$2"
  if [ ! -e "$_nus_path" ] && [ ! -L "$_nus_path" ]; then
    return 0
  fi
  _nus_err=""
  case "$(uname -s)" in
  Darwin)
    if ! _nus_err="$(/usr/bin/chflags -h nouchg "$_nus_path" 2>&1)"; then
      _nucleus_symlink_error "$_nus_context" "could not clear uchg from symlink $_nus_path before update" "$_nus_err"
      return 1
    fi
    ;;
  Linux)
    if command -v chattr >/dev/null; then
      if ! _nus_err="$(chattr -h -i "$_nus_path" 2>&1)"; then
        _nucleus_symlink_error "$_nus_context" "could not clear chattr +i from symlink $_nus_path before update" "$_nus_err"
        return 1
      fi
    fi
    ;;
  esac
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
    echo "ensure_file_symlink: error: $_efs_link exists and is not a symlink to $_efs_target; fix manually and re-apply" >&2
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
    echo "ensure_dir_symlink: error: $_eds_link exists and is not a symlink to $_eds_target; fix manually and re-apply" >&2
    return 1
  fi

  mkdir -p "$(dirname "$_eds_link")"
  ln -s "$_eds_target" "$_eds_link"
  _nucleus_protect_symlink "VS Code" "$_eds_link"
}
