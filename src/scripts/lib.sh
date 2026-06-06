# shellcheck shell=sh
# src/scripts/lib.sh — Shared library for nucleus POSIX shell scripts.
#
# Source this file at the top of any POSIX shell script under scripts/ or
# src/scripts/ after setting SCRIPT_DIR so REPO_ROOT can be derived
# automatically when needed.
#
# This file is a library meant to be sourced, not executed directly.
# Provides shared functions (usage_std, resolve_nucleus_root) for other
# scripts.
#
# Usage:
#   SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
#   . "${SCRIPT_DIR}/../src/scripts/lib.sh"
#
# Arguments:
#   (none)        This is a library; source it, do not execute.
#
# Environment variables:
#   NUCLEUS_REPO_ROOT  Override the detected repository root path (default: auto-detected via resolve_nucleus_root).
#
# Exit conditions:
#   N/A           This is a library; exit codes apply to the sourcing script.

# usage_std — Emit standardized usage text and exit.
#
# Usage: usage_std "script_name" "[options]" ["description"]
#
# Output format:
#   usage: script_name [options]
#   description (indented)
usage_std() {
  _us_name="$1"
  _us_opts="${2:-}"
  shift 2 2>/dev/null || true

  printf 'usage: %s %s\n' "$_us_name" "$_us_opts"
  if [ "$#" -gt 0 ]; then
    printf '  %s\n' "$1"
  fi
}

# resolve_nucleus_root — Print the absolute path of the nucleus repository root.
#
# Resolution order (Hybrid Precedence):
#   1. $NUCLEUS_REPO_ROOT environment variable (if non-empty and directory exists)
#   2. $HOME/.config/nucleus/repo-root file (first line, if directory exists)
#   3. git rev-parse --show-toplevel (if inside a git working tree)
#   4. $HOME/dev/nucleus (fallback)
resolve_nucleus_root() {
  if [ -n "${NUCLEUS_REPO_ROOT:-}" ] && [ -d "$NUCLEUS_REPO_ROOT" ]; then
    printf '%s\n' "$NUCLEUS_REPO_ROOT"
    return 0
  fi
  _rnr_config_file="$HOME/.config/nucleus/repo-root"
  if [ -f "$_rnr_config_file" ]; then
    _rnr_root="$(cat "$_rnr_config_file")"
    if [ -n "$_rnr_root" ] && [ -d "$_rnr_root" ]; then
      printf '%s\n' "$_rnr_root"
      return 0
    fi
  fi
  if _rnr_git_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    if [ -n "$_rnr_git_root" ] && [ -d "$_rnr_git_root" ]; then
      printf '%s\n' "$_rnr_git_root"
      return 0
    fi
  fi
  printf '%s\n' "$HOME/dev/nucleus"
}

# resolve_nucleus_host — Print the canonical host name.
#
# Resolution order (Hybrid Precedence):
#   1. $NUCLEUS_HOST environment variable (if non-empty)
#   2. Auto-detection from uname (Darwin → MacBook, Linux → NixOS)
resolve_nucleus_host() {
  if [ -n "${NUCLEUS_HOST:-}" ]; then
    printf '%s\n' "$NUCLEUS_HOST"
    return 0
  fi
  case "$(uname -s)" in
    Darwin) printf '%s\n' "MacBook" ;;
    Linux)  printf '%s\n' "NixOS" ;;
    *)      printf '%s\n' "Unknown" ;;
  esac
}

# merge_nix_config — Merge caller's NIX_CONFIG with required flake feature flags.
#
# Usage: merge_nix_config [features]
#
# Arguments:
#   features  Nix features string (default: "experimental-features = nix-command flakes").
#
# Environment:
#   NIX_CONFIG  Optional caller-provided nix configuration to merge.
merge_nix_config() {
  _mnc_features="${1:-experimental-features = nix-command flakes}"
  if [ -n "${NIX_CONFIG:-}" ]; then
    printf '%s\n%s' "$NIX_CONFIG" "$_mnc_features"
  else
    printf '%s' "$_mnc_features"
  fi
}

# require_command — Assert that a command exists in PATH.
#
# Usage: require_command command_name
#
# Arguments:
#   command_name  Name of the command to check.
#
# Exit conditions:
#   0 if found; prints error to stderr and exits 1 if missing.
require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '%s\n' "error: $1 is required but was not found in PATH" >&2
    exit 1
  fi
}

# sha256_of_file — Compute SHA-256 hex digest of a file.
#
# Usage: sha256_of_file file_path
#
# Tries sha256sum, then shasum -a 256, then openssl dgst -sha256.
# Calls require_command if no tool is available.
#
# Arguments:
#   file_path  Path to the file to hash.
sha256_of_file() {
  _sof_file="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$_sof_file" | awk '{ print $1 }'
    return
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$_sof_file" | awk '{ print $1 }'
    return
  fi

  require_command openssl
  openssl dgst -sha256 "$_sof_file" | awk '{ print $2 }'
}
