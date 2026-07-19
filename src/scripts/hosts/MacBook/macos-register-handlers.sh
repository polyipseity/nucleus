# Wrapper for registering default UTI handlers. Sources macos-launch-services-lib.sh
# and defines per-app helper functions. Each helper wraps register_handler with a
# fixed bundle ID and forwards remaining args (duti_bin + UTIs).
#
# Provided functions:
#   register_chrome_handler DUTI_BIN UTI [UTI ...]
#   register_keka_handler DUTI_BIN UTI [UTI ...]
#   register_vlc_handler DUTI_BIN UTI [UTI ...]
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../../lib/macos-launch-services-lib.sh"

register_chrome_handler() {
  register_handler "$1" "com.google.chrome" "${@:2}"
}

register_keka_handler() {
  register_handler "$1" "com.aone.keka" "${@:2}"
}

register_vlc_handler() {
  register_handler "$1" "org.videolan.vlc" "${@:2}"
}
