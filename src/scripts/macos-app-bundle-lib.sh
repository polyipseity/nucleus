# Shell helper variables for app bundle deployment.
# Sourced by Nix-inlined activation scripts in app-bundles.nix.
# Provides:
#   LSREGISTER — path to the lsregister binary
#   APP_DIR    — path to ~/Applications
#
# WHY explicit LSREGISTER path:
#   /usr/bin/lsregister does not exist on macOS; the binary lives inside the
#   LaunchServices framework bundle.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
APP_DIR="$HOME/Applications"
