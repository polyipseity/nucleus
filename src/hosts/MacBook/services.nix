# MacBook/services.nix — General macOS service configurations.
#
# Coordinates Quick Actions (services/quick-actions.nix) and App Services
# (services/app-services.nix) deployment. This file handles shared service
# lifecycle concerns that apply to all service types.
#
# For Quick Actions (Automator .workflow bundles appearing in right-click →
# Quick Actions): see services/quick-actions.nix
#
# For App Services (.app bundles appearing in menu bar → Services):
# see services/app-services.nix
{ lib, ... }:
let
  # Import centralized daemon refresh helper for cache flushing.
  daemonRefresh = import ../../modules/macos/daemon-refresh.nix;
in
{
  imports = [
    ./services/quick-actions.nix
    ./services/app-services.nix
  ];

  # Shared cache flush that runs after both Quick Actions and App Services
  # have been deployed. Each sub-module handles its own deploy and prune
  # lifecycle; this entry ensures final cache coherency.
  home.activation.deployNucleusServicesFlush =
    lib.hm.dag.entryAfter [ "deployNucleusQuickActions" "deployNucleusAppServices" ]
      ''
        # ── Phase 4: Flush daemon caches so changes take effect immediately ─
        # Without these restarts, cfprefsd, lsd, and pbs all hold stale cached
        # state in process memory. Finder is intentionally excluded here —
        # relaunchDesktopServices (DAG-ordered after writeBoundary) restarts it
        # via launchctl kickstart to preserve window state.
        ${daemonRefresh.refreshServicesMenu}
      '';
}
