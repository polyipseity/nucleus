#!/usr/bin/env bash
# Source this file (conceptually; in Nix it is inlined via builtins.readFile) to
# make macOS LaunchServices/launchctl helper functions available in
# home-manager activation scripts.  All functions are no-ops on non-macOS.
#
# Provided functions:
#   register_handler             — set default UTI handler via duti
#   launchctl_target             — build a launchctl service target specifier
#   launchctl_bootstrap_domain   — build a launchctl bootstrap domain target
#   launchctl_job_loaded         — is a launchd job loaded?
#   launchctl_bootout_wait       — unload a launchd job and wait for the unload
#   launchctl_bootstrap_plist    — load a plist, tolerating an already-loaded job
#   refresh_cfprefsd             — kill cfprefsd (CFPreferences daemon)
#   refresh_pbs                  — kill pbs (Pasteboard Server)
#   refresh_lsd                  — rebuild Launch Services database
#   refresh_finder               — restart Finder (killall)
#   refresh_finder_launchd       — restart Finder (launchctl, preserves windows)
#   refresh_dock                 — restart Dock
#   refresh_tiswitcher           — refresh TISwitcher input-source daemon
#   refresh_system_ui            — restart SystemUIServer + WindowManager
#   refresh_shared_filelistd     — restart sharedfilelistd
#   refresh_wallpaper_agent     — restart WallpaperAgent (wallpaper folder)
#   wait_for_daemons             — brief sleep for daemon flush settlement
#   refresh_desktop_services     — composite: Finder+SystemUI (launchctl)
#   refresh_services_menu        — composite: cfprefsd+pbs+sleep
#   rescan_pbs_services          — force a full pbs Services rescan (console user)

# register_handler DUTI_BIN BUNDLE_ID UTI [UTI ...]
# Sets BUNDLE_ID as the default handler for each UTI across all roles.
register_handler() {
  local duti_bin="$1"
  local handler="$2"
  shift 2
  for uti in "$@"; do
    if ! "$duti_bin" -s "$handler" "$uti" all; then
      die "failed to register LaunchServices handler $handler for UTI $uti."
    fi
  done
}

# launchctl_target — Build a macOS launchctl service target specifier.
# Pure formatter: domain + uid + label → target string. No environment
# dependencies, no defaults — every caller MUST provide all three.
#
# macOS 25+ requires gui/<uid>/<service> for user domain and
# system/<service> for system domain. Older macOS accepted bare service IDs.
#
# Args: $1 — domain ("system", "gui", or "user")
#       $2 — uid (numeric; ignored for system domain)
#       $3 — service label
launchctl_target() {
  local domain="$1" uid="$2" label="$3"
  case "$domain" in
  system) printf 'system/%s' "$label" ;;
  gui) printf 'gui/%s/%s' "$uid" "$label" ;;
  user) printf 'user/%s/%s' "$uid" "$label" ;;
  *) printf '%s/%s/%s' "$domain" "$uid" "$label" ;;
  esac
}

# launchctl_bootstrap_domain — Build a macOS launchctl bootstrap domain target.
# Pure formatter: domain + uid → bootstrap domain string. No environment
# dependencies, no defaults — every caller MUST provide both.
#
# bootstrap expects a domain target (system or gui/<uid>), not a service target.
#
# Args: $1 — domain ("system", "gui", or "user")
#       $2 — uid (numeric; ignored for system domain)
launchctl_bootstrap_domain() {
  local domain="$1" uid="$2"
  case "$domain" in
  system) printf 'system' ;;
  gui) printf 'gui/%s' "$uid" ;;
  user) printf 'user/%s' "$uid" ;;
  *) printf '%s/%s' "$domain" "$uid" ;;
  esac
}

# launchctl_job_loaded — Is a launchd job currently loaded?
# Args: $1 — launchctl service target (e.g. "gui/501/local.cloud-mount.iCloud")
#       $2 — sudo prefix ("" or "sudo")
# Returns: 0 when the job is loaded, launchctl's own non-zero status otherwise.
# WHY: loaded is what `launchctl` answers directly, and it is a different
#   question from "state = running": a job that is loaded but not running is not
#   missing, and a job that is missing cannot be started by `launchctl start`.
launchctl_job_loaded() {
  local target="$1" sudo_prefix="$2"
  # check-suppress:suppression_doc: an unloaded job is the question being asked, not an error.
  $sudo_prefix launchctl print "$target" >/dev/null 2>&1
}

# launchctl_bootout_wait — Unload a launchd job and wait until it is really gone.
# Args: $1 — launchctl service target (e.g. "gui/501/local.cloud-mount.iCloud")
#       $2 — sudo prefix ("" or "sudo")
# Returns: 0 when the job is no longer loaded (or was never loaded), 1 when it is
#          still loaded after the bounded wait.
# WHY: macOS 26+ unloads asynchronously, so a `bootstrap` issued right after
#   `bootout` can fail with "Bootstrap failed: 5: Input/output error" because the
#   job is still loaded — and the bootout that completes afterwards then leaves
#   the service unloaded and silent.  Home Manager's activation uses
#   `launchctl bootout --wait` for the same reason; polling covers older macOS,
#   where --wait does not exist.
launchctl_bootout_wait() {
  local target="$1" sudo_prefix="$2"
  local major
  # check-suppress:suppression_doc: sw_vers is absent off macOS and an unknown version takes the plain bootout path.
  major="$(sw_vers -productVersion 2>/dev/null | cut -d. -f1 || true)"
  case "$major" in
  '' | *[!0-9]*) major=0 ;;
  esac
  # check-suppress:suppression_doc: an already-absent job needs no unload; bootout exits 1 for it.
  if [ "$major" -ge 26 ]; then
    # check-suppress:suppression_doc: the poll below is the check; an absent job already satisfies it.
    $sudo_prefix launchctl bootout --wait "$target" >/dev/null 2>&1 || true
  else
    # check-suppress:suppression_doc: the poll below is the check; an absent job already satisfies it.
    $sudo_prefix launchctl bootout "$target" >/dev/null 2>&1 || true
  fi
  local _i=0
  while [ "$_i" -lt 10 ]; do
    launchctl_job_loaded "$target" "$sudo_prefix" || return 0
    sleep 0.5
    _i=$((_i + 1))
  done
  return 1
}

# launchctl_bootstrap_plist — Load a plist into a launchd domain, tolerating an
# already-loaded job and the asynchronous-unload race.
# Args: $1 — bootstrap domain target (e.g. "gui/501", "system")
#       $2 — plist path (e.g. "$HOME/Library/LaunchAgents/local.foo.plist")
#       $3 — launchctl service target of that same job (e.g. "gui/501/local.foo")
#       $4 — sudo prefix ("" or "sudo")
# Output: launchctl's own output when the job could not be loaded; nothing on
#         success, so a caller can quote the reason in its own error.
# Returns: 0 when the job is loaded afterwards, 1 otherwise.
# WHY: bootstrapping an already-loaded job only fails with "Bootstrap failed: 5:
#   Input/output error", so the loaded case is the healthy case and is never
#   passed to launchctl.  Code 5 on an unloaded job means a preceding
#   asynchronous bootout has not finished yet, so the unload is waited out and
#   the bootstrap retried instead of the service being reported as broken.
launchctl_bootstrap_plist() {
  local domain="$1" plist="$2" target="$3" sudo_prefix="$4"
  if launchctl_job_loaded "$target" "$sudo_prefix"; then
    return 0
  fi

  local out="" _i=0
  while [ "$_i" -lt 3 ]; do
    if out=$($sudo_prefix launchctl bootstrap "$domain" "$plist" 2>&1); then
      return 0
    fi
    case "$out" in
    *"Bootstrap failed: 5:"*)
      # check-suppress:suppression_doc: a job that is already gone satisfies the wait; the bootstrap retry reports the outcome.
      launchctl_bootout_wait "$target" "$sudo_prefix" || true
      ;;
    *)
      break
      ;;
    esac
    _i=$((_i + 1))
  done
  printf '%s\n' "$out"
  return 1
}

# refresh_cfprefsd — Kill cfprefsd (CFPreferences daemon) on macOS.
# Caches all defaults read/write in process memory; kill forces re-read from
# plist on next access.  No-op on non-macOS.
refresh_cfprefsd() {
  case "$(uname -s)" in
  Darwin)
    # check-suppress:suppression_doc: cfprefsd may not be running; killall exits 1 for absent processes.
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
    # check-suppress:suppression_doc: pbs may not be running; killall exits 1 for absent processes.
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
    # check-suppress:suppression_doc: lsd may have already been killed by a previous step; best-effort db rebuild.
    /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -kill -domain user 2>/dev/null || true
    ;;
  esac
}

# refresh_finder — Restart Finder on macOS via killall.
# No-op on non-macOS.
refresh_finder() {
  case "$(uname -s)" in
  Darwin)
    # check-suppress:suppression_doc: Finder may not be running on headless session; killall exits 1 for absent processes.
    /usr/bin/killall Finder 2>/dev/null || true
    ;;
  esac
}

# refresh_dock — Restart Dock on macOS via killall.
# No-op on non-macOS.
refresh_dock() {
  case "$(uname -s)" in
  Darwin)
    # check-suppress:suppression_doc: Dock may not be running on headless session; killall exits 1 for absent processes.
    /usr/bin/killall Dock 2>/dev/null || true # check-suppress:suppression_doc: Dock may not be running (headless/SSH session); only restarted when console user is active
    ;;
  esac
}
# refresh_tiswitcher — Refresh TISwitcher (input-source switcher daemon).
# Sends HUP so custom key layout / TIS preferences reload without restarting
# the whole input-method pipeline.
refresh_tiswitcher() {
  case "$(uname -s)" in
  Darwin)
    /usr/bin/killall -HUP TISwitcher 2>/dev/null || true # check-suppress:suppression_doc: TISwitcher may not be running; only restarted when needed
    ;;
  esac
}

# refresh_system_ui — Restart SystemUIServer (menu bar extras) and
# WindowManager (Spaces) on macOS.
refresh_system_ui() {
  case "$(uname -s)" in
  Darwin)
    for _sui_proc in SystemUIServer WindowManager; do
      /usr/bin/killall "$_sui_proc" 2>/dev/null || true # check-suppress:suppression_doc: proc may not be running; only restarted when needed
    done
    ;;
  esac
}

# refresh_shared_filelistd — Restart sharedfilelistd (Finder sidebar daemon).
refresh_shared_filelistd() {
  case "$(uname -s)" in
  Darwin)
    /usr/bin/killall sharedfilelistd 2>/dev/null || true # check-suppress:suppression_doc: sharedfilelistd may not be running; only restarted when needed
    ;;
  esac
}

# refresh_finder_launchd — Restart Finder via launchctl kickstart.
# Preserves window state. Preferred over killall for desktop refreshes.
# Finder is always in the GUI domain — not configurable.
refresh_finder_launchd() {
  case "$(uname -s)" in
  Darwin)
    /bin/launchctl kickstart -k "gui/$UID/com.apple.Finder" 2>/dev/null || true # check-suppress:suppression_doc: Finder may not be running or user may be in headless/SSH session
    ;;
  esac
}

# refresh_wallpaper_agent — Restart WallpaperAgent on macOS to force re-read
# of wallpaper folder contents after provisioning new wallpapers.
# WallpaperAgent holds folder contents in-memory; kill forces re-read.
# No-op on non-macOS.
refresh_wallpaper_agent() {
  case "$(uname -s)" in
  Darwin)
    /usr/bin/killall WallpaperAgent 2>/dev/null || true # check-suppress:suppression_doc: WallpaperAgent may not be running; killall exits 1 for absent processes
    ;;
  esac
}

# wait_for_daemons — Brief sleep for killed daemons to flush and restart.
wait_for_daemons() {
  /bin/sleep 1
}

# refresh_desktop_services — Composite: restart UI daemons for desktop config
# changes. Preserves Finder window state via launchctl kickstart.
refresh_desktop_services() {
  refresh_finder_launchd
  refresh_system_ui
}
# refresh_services_menu — Full flush of the Services menu pipeline on macOS.
# Kills cfprefsd, lsd, pbs, waits 1 s, then restarts Finder.
# Call this after deploying or removing .app bundles so the Services menu
# reflects the new state without a logout/reboot.
# No-op on non-macOS.
refresh_services_menu() {
  case "$(uname -s)" in
  Darwin)
    # check-suppress:suppression_doc: see refresh_cfprefsd -- daemon may not be running.
    /usr/bin/killall -KILL cfprefsd 2>/dev/null || true
    # check-suppress:suppression_doc: see refresh_lsd -- LS db may already be fresh.
    /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -kill -domain user 2>/dev/null || true
    # check-suppress:suppression_doc: see refresh_pbs -- pasteboard server may not be running.
    /usr/bin/killall -KILL pbs 2>/dev/null || true
    /bin/sleep 1
    # check-suppress:suppression_doc: see refresh_finder -- Finder may not be running.
    /usr/bin/killall Finder 2>/dev/null || true
    ;;
  esac
}

# rescan_pbs_services PBS_BIN LAUNCHCTL_BIN SUDO_BIN UID USER
# Force a complete Services rescan and refresh the services pasteboard.
#
# WHY: killing pbs only re-reads its caches. pbs detects changed Services via
# FSEvents, which never fires for a bundle replaced or renamed in place, so a
# renamed workflow kept its stale registration and newly provisioned ones
# stayed invisible until the next login. `pbs -update` does a complete rescan
# and rewrites the userdef cache and the services pasteboard that the menus are
# built from (verified: 2 of 7 nucleus services registered before, 7 after).
#
# A bare `pbs` run is not an option: this build rejects it with
# `Usage: pbs [-debug] [-dump] [-dump_cache] [-read_bundle file] [-update]
# [-flush] language1 language2...` on stderr and exit status 1.
#
# Runs in the console user's session: pbs keeps per-user caches, so running it
# as root would refresh root's Services instead of the logged-in user's.
rescan_pbs_services() {
  local _rps_pbs_bin _rps_launchctl_bin _rps_sudo_bin _rps_uid _rps_user
  _rps_pbs_bin="$1"
  _rps_launchctl_bin="$2"
  _rps_sudo_bin="$3"
  _rps_uid="$4"
  _rps_user="$5"
  "$_rps_launchctl_bin" asuser "$_rps_uid" "$_rps_sudo_bin" -H -u "$_rps_user" "$_rps_pbs_bin" -update
}
