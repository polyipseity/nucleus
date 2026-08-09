# shellcheck shell=sh
# Shared CLI argument parser for nucleus activation bundle scripts.
#
# Source this at the top of each bundle script via:
#   SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
#   . "$SCRIPT_DIR/../lib/argparse.sh"
#
# Parsing convention:
#   --key value    — stores "$key=$value" in _ab_args
#   --flag         — stores "$flag=1" in _ab_args
#   --             — end of named args; remaining tokens are positional
#   Everything after the first positional token is treated as positional.
#
# After _ab_parse_args "$@":
#   _ab_get_arg key       — prints value for --key, empty if not set
#   _ab_get_arg_bool flag — prints 1 if --flag was passed, 0 otherwise
#   _ab_positional        — semicolon-joined positional args (use IFS splitting)
#   _ab_positional_count  — number of positional args
#
# All internal names start with _ab_ to avoid collision.
# Uses read/printf with IFS=\n for multi-line safety.

# Reset state
_ab_args_file=$(mktemp)
_ab_positional_file=$(mktemp)
_ab_positional_count=0

_ab_parse_args() {
  _ab_end_named=false
  for _ab_arg in "$@"; do
    if [ "$_ab_end_named" = true ]; then
      printf '%s\n' "$_ab_arg" >>"$_ab_positional_file"
      _ab_positional_count=$((_ab_positional_count + 1))
    elif [ "$_ab_arg" = "--" ]; then
      _ab_end_named=true
    elif [ "${_ab_arg#--}" != "$_ab_arg" ] && [ "${_ab_arg#--}" != "" ]; then
      # --key or --key=value
      _ab_key="${_ab_arg#--}"
      case "$_ab_key" in
      *=*)
        _ab_k="${_ab_key%%=*}"
        _ab_v="${_ab_key#*=}"
        printf '%s=%s\n' "$_ab_k" "$_ab_v" >>"$_ab_args_file"
        ;;
      *)
        # --key value: read next arg as value
        _ab_k="$_ab_key"
        if [ $# -gt 1 ]; then
          shift
          _ab_v="$1"
        else
          _ab_v=""
        fi
        printf '%s=%s\n' "$_ab_k" "$_ab_v" >>"$_ab_args_file"
        ;;
      esac
    else
      # Positional argument
      printf '%s\n' "$_ab_arg" >>"$_ab_positional_file"
      _ab_positional_count=$((_ab_positional_count + 1))
    fi
    shift
  done
}

# _ab_get_arg KEY — prints the value for --KEY, empty if not set
_ab_get_arg() {
  _ab_key="$1"
  while IFS= read -r _ab_line; do
    case "$_ab_line" in
    "${_ab_key}="*)
      printf '%s\n' "${_ab_line#*=}"
      return 0
      ;;
    esac
  done <"$_ab_args_file"
  return 0
}

# _ab_get_arg_bool FLAG — prints 1 if --FLAG was passed, 0 otherwise
_ab_get_arg_bool() {
  _ab_key="$1"
  while IFS= read -r _ab_line; do
    case "$_ab_line" in
    "${_ab_key}="*)
      printf '%s\n' "1"
      return 0
      ;;
    esac
  done <"$_ab_args_file"
  printf '%s\n' "0"
}

_ab_cleanup() {
  rm -f "$_ab_args_file" "$_ab_positional_file"
}

# Registers cleanup on EXIT
trap _ab_cleanup EXIT
