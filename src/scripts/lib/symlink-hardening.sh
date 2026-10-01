# shellcheck shell=sh
# Set/clear immutable flags on symlinks so managed agent config symlinks are
# not removed or replaced outside an apply run. Only macOS can do this from a
# user-scope activation; Linux enforces the contract by detection, see the WHY
# in each Linux arm.

# WHY: a flag change that genuinely fails is an error, and an absent path is not
# a failure at all: the post-linkGeneration seeders create several managed
# symlinks, so unprotect/protect legitimately run before they exist. Failures
# return non-zero instead of exiting because this library is inlined into
# activation blocks and sourced by scripts that do not all provide `die`; every
# caller runs under `set -e`, so the non-zero return aborts the activation.
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
    # WHY: chattr needs CAP_LINUX_IMMUTABLE, which a login-user activation does
    # not have, and nucleus does not ship e2fsprogs on that PATH: with the
    # binary present the call would fail EPERM, and a genuine flag failure is
    # fatal here, so every NixOS apply would abort. The contract is enforced by
    # detection instead: check step 13 fails when a managed symlink does not
    # resolve into the live repo, and home.activation.verify-managed-symlink-paths
    # fails when a seeded path is missing. macOS keeps prevention via uchg.
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
    # WHY: see _nucleus_protect_symlink; the capability is unavailable in a
    # user-scope activation, so NixOS relies on detection.
    ;;
  esac
}

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
