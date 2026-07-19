# Source this file (conceptually; in Nix it is inlined via builtins.readFile) to
# make macOS LaunchServices/launchctl helper functions available in
# home-manager activation scripts.  All functions are no-ops on non-macOS.
#
# Provided functions:
#   register_handler           — set default UTI handler via duti
#   launchctl_target           — build a launchctl service target specifier
#   launchctl_bootstrap_domain — build a launchctl bootstrap domain target
#   refresh_cfprefsd           — kill cfprefsd (CFPreferences daemon)
#   refresh_pbs                — kill pbs (Pasteboard Server)
#   refresh_lsd                — rebuild Launch Services database
#   refresh_finder             — restart Finder
#   refresh_dock               — restart Dock
#   refresh_services_menu      — full Services menu pipeline flush

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

# launchctl_target — Build a macOS launchctl service target specifier.
# macOS 25+ requires gui/<uid>/<service> for user domain and
# system/<service> for system domain. Older macOS accepted bare service IDs.
launchctl_target() {
  if [ "$1" = "system" ]; then
    printf 'system/%s' "$2"
  else
    printf 'gui/%s/%s' "$(id -u)" "$2"
  fi
}

# launchctl_bootstrap_domain — Build a macOS launchctl bootstrap domain target.
# bootstrap expects a domain target (system or gui/<uid>), not a service target.
# macOS 26 dropped the "user" alias; gui/<uid> is the only valid form for user.
launchctl_bootstrap_domain() {
  if [ "$1" = "system" ]; then
    printf 'system'
  else
    printf 'gui/%s' "$(id -u)"
  fi
}

# refresh_cfprefsd — Kill cfprefsd (CFPreferences daemon) on macOS.
# Caches all defaults read/write in process memory; kill forces re-read from
# plist on next access.  No-op on non-macOS.
refresh_cfprefsd() {
  case "$(uname -s)" in
    Darwin)
      # undoc-supp: cfprefsd may not be running; killall exits 1 for absent processes.
      /usr/bin/killall -KILL cfprefsd 2>/dev/null || true
      ;;
  esac
}

# refresh_pbs — Kill pbs (Pasteboard Server + Services manager) on macOS.
# Caches NSServicesStatus at startup; kill forces re-read of pbs.plist so
# new/changed services appear in menus.  No-op on non-macOS.
refresh_pbs() {
  case "$(uname -s)" in
    Darwin)
      # undoc-supp: pbs may not be running; killall exits 1 for absent processes.
      /usr/bin/killall -KILL pbs 2>/dev/null || true
      ;;
  esac
}

# refresh_lsd — Rebuild the Launch Services database on macOS.
# Kills lsd (Launch Services Daemon); on restart it rebuilds from scratch,
# picking up newly registered .app bundles.  No-op on non-macOS.
refresh_lsd() {
  case "$(uname -s)" in
    Darwin)
      # undoc-supp: lsd may have already been killed by a previous step; best-effort db rebuild.
      /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -kill -domain user 2>/dev/null || true
      ;;
  esac
}

# refresh_finder — Restart Finder on macOS via killall.
# No-op on non-macOS.
refresh_finder() {
  case "$(uname -s)" in
    Darwin)
      # undoc-supp: Finder may not be running on headless session; killall exits 1 for absent processes.
      /usr/bin/killall Finder 2>/dev/null || true
      ;;
  esac
}

# refresh_dock — Restart Dock on macOS via killall.
# No-op on non-macOS.
refresh_dock() {
  case "$(uname -s)" in
    Darwin)
      # undoc-supp: Dock may not be running on headless session; killall exits 1 for absent processes.
      /usr/bin/killall Dock 2>/dev/null || true
      ;;
  esac
}

# refresh_services_menu — Full flush of the Services menu pipeline on macOS.
# Kills cfprefsd, lsd, pbs, waits 1 s, then restarts Finder.
# Call this after deploying or removing .app bundles so the Services menu
# reflects the new state without a logout/reboot.
# No-op on non-macOS.
refresh_services_menu() {
  case "$(uname -s)" in
    Darwin)
      # undoc-supp: see refresh_cfprefsd — daemon may not be running.
      /usr/bin/killall -KILL cfprefsd 2>/dev/null || true
      # undoc-supp: see refresh_lsd — LS db may already be fresh.
      /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -kill -domain user 2>/dev/null || true
      # undoc-supp: see refresh_pbs — pasteboard server may not be running.
      /usr/bin/killall -KILL pbs 2>/dev/null || true
      /bin/sleep 1
      # undoc-supp: see refresh_finder — Finder may not be running.
      /usr/bin/killall Finder 2>/dev/null || true
      ;;
  esac
}
