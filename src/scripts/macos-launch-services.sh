# register_handler BUNDLE_ID UTI [UTI ...]
# Sets BUNDLE_ID as the default handler for each UTI across all roles.
# Uses DUTI_BIN environment variable (set by Nix wrapper).
set -eu

register_handler() {
  handler="$1"
  shift
  for uti in "$@"; do
    if ! "$DUTI_BIN" -s "$handler" "$uti" all; then
      echo "macos: failed to register LaunchServices handler $handler for UTI $uti." >&2
    fi
  done
}
