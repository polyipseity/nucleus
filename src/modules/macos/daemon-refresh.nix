# macOS daemon refresh helpers.
#
# Provides shell snippets for restarting macOS daemons that cache state in
# process memory. All targeted daemons are managed by launchd and restart
# automatically after SIGKILL.
#
# All daemon restarts for a given OS are centralized here for macOS, in
# Set-NucleusService.ps1 for Windows SCM operations, and in lib.sh shell
# functions for cross-platform scripts. Every daemon/service must be
# restarted at most once per activation run — no redundant kills.
# See: AGENTS.md > Core Conventions for the cross-OS principle.
rec {
  # Full path to lsregister (Launch Services database utility).
  # Used by refreshLsd and by app-services.nix for app registration.
  lsregisterPath = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister";

  # Kill cfprefsd (CFPreferences daemon).
  # Caches all defaults read/write in process memory. Kill forces re-read from
  # ~/Library/Preferences/*.plist on next access.
  # Source: https://www.manpagez.com/man/1/defaults/
  refreshCfprefsd = ''
    /usr/bin/killall -KILL cfprefsd 2>/dev/null || true
  '';

  # Kill pbs (Pasteboard Server + Services manager).
  # Caches NSServicesStatus (service enablement toggles in pbs.plist) at
  # startup. Kill forces re-read so new/changed services appear in menus.
  refreshPbs = ''
    /usr/bin/killall -KILL pbs 2>/dev/null || true
  '';

  # Rebuild the Launch Services database for the user domain.
  # Sends SIGKILL to lsd (Launch Services Daemon); on restart it rebuilds
  # the database from scratch, picking up newly registered .app bundles.
  refreshLsd = ''
    ${lsregisterPath} -kill -domain user 2>/dev/null || true
  '';

  # Restart Finder via killall. Simpler than launchctl kickstart but loses
  # window state. Used for services-menu refreshes where window state is
  # irrelevant.
  refreshFinderKillall = ''
    /usr/bin/killall Finder 2>/dev/null || true
  '';

  # Restart Finder via launchctl kickstart. Preserves window state.
  # Preferred for desktop configuration reloads.
  refreshFinderLaunchd = ''
    /bin/launchctl kickstart -k "gui/$UID/com.apple.Finder" 2>/dev/null || true
  '';

  # Convenience alias — favors launchctl for desktop refreshes.
  refreshFinder = refreshFinderLaunchd;

  # Restart sharedfilelistd (Finder sidebar daemon).
  refreshSharedFilelistd = ''
    /usr/bin/killall sharedfilelistd 2>/dev/null || true
  '';

  # Restart Dock.
  refreshDock = ''
    /usr/bin/killall Dock 2>/dev/null || true
  '';

  # Restart SystemUIServer (menu bar extras) and WindowManager (Spaces).
  refreshSystemUI = ''
    for _dr_proc in SystemUIServer WindowManager; do
      /usr/bin/killall "$_dr_proc" 2>/dev/null || true
    done
  '';

  # Restart TISwitcher (input-source switcher daemon).
  refreshTISwitcher = ''
    /usr/bin/killall -HUP TISwitcher 2>/dev/null || true
  '';

  # Wait for killed daemons to flush and restart.
  # Some daemons (pbs, cfprefsd) need a brief settling window before clients
  # (Finder, System Settings) can query their re-initialized state.
  waitForDaemons = ''
    /bin/sleep 1
  '';

  # Composite: flush the services menu daemon pipeline.
  # Does not restart Finder — the dedicated relaunchDesktopServices phase
  # (in macos.nix) handles that later via launchctl kickstart with window
  # state preservation.
  refreshServicesMenu = ''
    ${refreshCfprefsd}
    ${refreshLsd}
    ${refreshPbs}
    ${waitForDaemons}
  '';

  # Composite: restart UI daemons for desktop configuration changes.
  # Does not restart cfprefsd or sharedfilelistd — those are killed by
  # configureFinderSidebar (DAG-ordered immediately before this in macos.nix).
  # Preserves Finder window state via launchctl kickstart.
  refreshDesktopServices = ''
    ${refreshFinderLaunchd}
    ${refreshSystemUI}
  '';
}
