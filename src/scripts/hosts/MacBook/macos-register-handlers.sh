# Self-executing registration of default UTI handlers.
# Sources macos-launch-services-lib.sh and registers handlers with token
# placeholders substituted at Nix eval time.
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../../lib/macos-launch-services-lib.sh"

register_handler "__DUTI_BIN__" "com.google.chrome" __CHROME_UTIS__
register_handler "__DUTI_BIN__" "com.aone.keka" __KEKA_UTIS__
register_handler "__DUTI_BIN__" "org.videolan.vlc" __VLC_UTIS__
