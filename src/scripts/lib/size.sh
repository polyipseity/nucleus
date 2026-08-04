# shellcheck shell=bash
# parse_size SIZE_STRING
#   Parses a suffixed size string (^[0-9]+ ?(kB|MB|GB|TB|kiB|MiB|GiB|TiB)$)
#   into an exact byte count.  Decimal prefixes (kB/MB/GB/TB) multiply by
#   powers of 10; binary prefixes (kiB/MiB/GiB/TiB) by powers of 2.  A single
#   optional space between the number and the prefix is allowed.  The grammar
#   is case-sensitive (KB/KiB are invalid).  Invalid strings print an error and
#   return non-zero.  Keep in sync with src/modules/lib/size.nix and
#   src/hosts/Windows/modules/SizeStrings.ps1.
parse_size() {
  # The regex lives in a variable: an unquoted space + quantifier inside a
  # literal =~ RHS confuses shellcheck 0.11's parser (SC1072/SC1073).
  local _ps_regex='^([0-9]+) ?(kB|MB|GB|TB|kiB|MiB|GiB|TiB)$'
  local _ps_input="$1" _ps_number _ps_suffix _ps_factor _ps_bytes
  if ! [[ "$_ps_input" =~ $_ps_regex ]]; then
    error "invalid size string '$_ps_input' (expected ^[0-9]+ ?(kB|MB|GB|TB|kiB|MiB|GiB|TiB)$)"
    return 1
  fi
  _ps_number="${BASH_REMATCH[1]}"
  _ps_suffix="${BASH_REMATCH[2]}"
  case "$_ps_suffix" in
    kB) _ps_factor=1000 ;;
    MB) _ps_factor=1000000 ;;
    GB) _ps_factor=1000000000 ;;
    TB) _ps_factor=1000000000000 ;;
    kiB) _ps_factor=1024 ;;
    MiB) _ps_factor=1048576 ;;
    GiB) _ps_factor=1073741824 ;;
    TiB) _ps_factor=1099511627776 ;;
  esac
  _ps_bytes=$((_ps_number * _ps_factor))
  printf '%s\n' "$_ps_bytes"
}
