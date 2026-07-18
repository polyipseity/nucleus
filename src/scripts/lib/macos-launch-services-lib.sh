# register_handler DUTI_BIN BUNDLE_ID UTI [UTI ...]
# Sets BUNDLE_ID as the default handler for each UTI across all roles.
register_handler() {
  local duti_bin="$1"
  local handler="$2"
  shift 2
  for uti in "$@"; do
    if ! "$duti_bin" -s "$handler" "$uti" all; then
      echo "macos: failed to register LaunchServices handler $handler for UTI $uti." >&2
    fi
  done
}
