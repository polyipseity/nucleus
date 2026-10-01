#!/usr/bin/env bash
# macOS launchctl and LaunchServices helpers for home-manager activation. Every refresh_* function is a no-op off macOS.
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

# macOS 25+ requires gui/<uid>/<service> and system/<service>; older macOS accepted bare service ids.
launchctl_target() {
  local domain="$1" uid="$2" label="$3"
  case "$domain" in
  system) printf 'system/%s' "$label" ;;
  gui) printf 'gui/%s/%s' "$uid" "$label" ;;
  user) printf 'user/%s/%s' "$uid" "$label" ;;
  *) printf '%s/%s/%s' "$domain" "$uid" "$label" ;;
  esac
}

# A root process still addresses the logged-in user's gui session, so there the console user's uid is the session owner. /dev/console is unreadable when nobody is logged in, and root is then the only uid left.
launchctl_session_uid() {
  local uid
  uid="$(id -u)"
  if [ "$uid" = "0" ]; then
    # check-suppress:suppression_doc: /dev/console is unreadable headless; the effective uid is the only remaining answer
    uid="$(/usr/bin/stat -f%u /dev/console 2>/dev/null || true)"
    [ -n "$uid" ] || uid=0
  fi
  printf '%s' "$uid"
}

# WHY: launchdDomain names only the per-user domain (gui vs user) and is absent from system-scope entries. Defaulting it to "gui" for every entry addresses a system daemon inside the GUI session, where launchd has never loaded it, so every status probe reports "not loaded" and every start targets a domain the job does not belong to.
supervisor_resolve_target() {
  local scope="$1" domain="$2" label="$3"
  case "$scope" in
  system) launchctl_target system "" "$label" ;;
  *) launchctl_target "${domain:-gui}" "$(launchctl_session_uid)" "$label" ;;
  esac
}

# bootstrap takes a domain target (system or gui/<uid>), not a service target.
launchctl_bootstrap_domain() {
  local domain="$1" uid="$2"
  case "$domain" in
  system) printf 'system' ;;
  gui) printf 'gui/%s' "$uid" ;;
  user) printf 'user/%s' "$uid" ;;
  *) printf '%s/%s' "$domain" "$uid" ;;
  esac
}

# WHY: loaded is a different question from "state = running", because a job that is loaded but not running is not missing, and `launchctl start` cannot start a job that is missing.
launchctl_job_loaded() {
  local target="$1" sudo_prefix="$2"
  # check-suppress:suppression_doc: an unloaded job is the question being asked, not an error.
  $sudo_prefix launchctl print "$target" >/dev/null 2>&1
}

# WHY: macOS 26+ unloads asynchronously, so a `bootstrap` issued right after `bootout` can fail with "Bootstrap failed: 5: Input/output error" while the job is still loaded, and the bootout that completes afterwards leaves the service unloaded and silent. Home Manager uses `launchctl bootout --wait` for the same reason; the poll covers older macOS, where --wait does not exist.
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

# Prints launchctl's own output on failure so a caller can quote the reason.
# WHY: bootstrapping an already-loaded job only fails with "Bootstrap failed: 5: Input/output error", so the loaded case is the healthy case and never reaches launchctl. Code 5 on an unloaded job means a preceding asynchronous bootout has not finished, so the unload is waited out and the bootstrap retried instead of the service being reported as broken.
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

# cfprefsd caches defaults in process memory; kill forces a re-read from the plist.
refresh_cfprefsd() {
  case "$(uname -s)" in
  Darwin)
    # check-suppress:suppression_doc: cfprefsd may not be running; killall exits 1 for absent processes.
    /usr/bin/killall -KILL cfprefsd 2>/dev/null || true
    ;;
  esac
}

# pbs caches NSServicesStatus at startup; kill forces a re-read of pbs.plist.
refresh_pbs() {
  case "$(uname -s)" in
  Darwin)
    # check-suppress:suppression_doc: pbs may not be running; killall exits 1 for absent processes.
    /usr/bin/killall -KILL pbs 2>/dev/null || true
    ;;
  esac
}

# lsd rebuilds its database from scratch on restart, picking up new .app bundles.
refresh_lsd() {
  case "$(uname -s)" in
  Darwin)
    # check-suppress:suppression_doc: lsd may have already been killed by a previous step; best-effort db rebuild.
    /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -kill -domain user 2>/dev/null || true
    ;;
  esac
}

refresh_finder() {
  case "$(uname -s)" in
  Darwin)
    # check-suppress:suppression_doc: Finder may not be running on headless session; killall exits 1 for absent processes.
    /usr/bin/killall Finder 2>/dev/null || true
    ;;
  esac
}

refresh_dock() {
  case "$(uname -s)" in
  Darwin)
    # check-suppress:suppression_doc: Dock may not be running on headless session; killall exits 1 for absent processes.
    /usr/bin/killall Dock 2>/dev/null || true # check-suppress:suppression_doc: Dock may not be running (headless/SSH session); only restarted when console user is active
    ;;
  esac
}
# HUP reloads custom key layout and TIS preferences without restarting the
# input-method pipeline.
refresh_tiswitcher() {
  case "$(uname -s)" in
  Darwin)
    /usr/bin/killall -HUP TISwitcher 2>/dev/null || true # check-suppress:suppression_doc: TISwitcher may not be running; only restarted when needed
    ;;
  esac
}

refresh_system_ui() {
  case "$(uname -s)" in
  Darwin)
    for _sui_proc in SystemUIServer WindowManager; do
      /usr/bin/killall "$_sui_proc" 2>/dev/null || true # check-suppress:suppression_doc: proc may not be running; only restarted when needed
    done
    ;;
  esac
}

refresh_shared_filelistd() {
  case "$(uname -s)" in
  Darwin)
    /usr/bin/killall sharedfilelistd 2>/dev/null || true # check-suppress:suppression_doc: sharedfilelistd may not be running; only restarted when needed
    ;;
  esac
}

# launchctl kickstart preserves window state, so prefer it over killall, and Finder always lives in the gui domain.
refresh_finder_launchd() {
  case "$(uname -s)" in
  Darwin)
    /bin/launchctl kickstart -k "gui/$UID/com.apple.Finder" 2>/dev/null || true # check-suppress:suppression_doc: Finder may not be running or user may be in headless/SSH session
    ;;
  esac
}

# WallpaperAgent holds folder contents in memory, so kill forces a re-read.
refresh_wallpaper_agent() {
  case "$(uname -s)" in
  Darwin)
    /usr/bin/killall WallpaperAgent 2>/dev/null || true # check-suppress:suppression_doc: WallpaperAgent may not be running; killall exits 1 for absent processes
    ;;
  esac
}

wait_for_daemons() {
  /bin/sleep 1
}

refresh_desktop_services() {
  refresh_finder_launchd
  refresh_system_ui
}
# Full flush of the Services menu pipeline. Run after deploying or removing .app bundles so the menu updates without a logout.
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

# WHY: killing pbs only re-reads its caches and FSEvents never fires for a bundle replaced or renamed in place, so a renamed workflow kept its stale registration and new ones stayed invisible until the next login. `pbs -update` rescans and rewrites the cache the menus are built from, and a bare `pbs` is not an option because this build prints usage and exits 1.
#
# Runs in the console user's session because pbs caches are per user; as root it would refresh root's services instead.
rescan_pbs_services() {
  local _rps_pbs_bin _rps_launchctl_bin _rps_sudo_bin _rps_uid _rps_user
  _rps_pbs_bin="$1"
  _rps_launchctl_bin="$2"
  _rps_sudo_bin="$3"
  _rps_uid="$4"
  _rps_user="$5"
  "$_rps_launchctl_bin" asuser "$_rps_uid" "$_rps_sudo_bin" -H -u "$_rps_user" "$_rps_pbs_bin" -update
}
