# MacBook/services.nix — General macOS service configurations.
#
# Coordinates Quick Actions (services/quick-actions.nix) and App Services
# (services/app-services.nix) deployment. This file handles shared daemon
# cache flush that runs after both sub-modules have deployed, so changes
# from both Quick Actions (NSServicesStatus) and App Services
# (LaunchServices registration) take effect in one activation.
#
# For Quick Actions (Automator .workflow bundles appearing in right-click →
# Quick Actions): see services/quick-actions.nix
#
# For App Services (.app bundles appearing in menu bar → Services):
# see services/app-services.nix
{ lib, ... }:
let
  # Import centralized daemon refresh helpers for post-deploy cache flush.
  daemonRefresh = import ../../modules/macos/daemon-refresh.nix;

  # Generate a plist <dict> from an attribute set of booleans.
  # Used to build NSServicesStatus presentation_modes values.
  mkPresentationModes =
    modes:
    let
      boolStr = v: if v then "true" else "false";
      entries = lib.mapAttrsToList (name: value: "<key>${name}</key><${boolStr value}/>") modes;
    in
    "<dict>${builtins.concatStringsSep "" entries}</dict>";
in
{
  imports = [
    ./services/quick-actions.nix
    ./services/app-services.nix
  ];

  # Inject shared helpers into sub-modules.
  _module.args = { inherit mkPresentationModes; };

  # Shared cache flush that runs after both Quick Actions and App Services
  # have been deployed. Each sub-module handles its own deploy and prune
  # lifecycle; this entry ensures final cache coherency.
  home.activation.deployNucleusServicesFlush =
    lib.hm.dag.entryAfter [ "deployNucleusQuickActions" "deployNucleusAppServices" ]
      ''
        # ── Phase 4: Flush daemon caches so changes take effect immediately ─
        # Without these restarts, cfprefsd and pbs hold stale cached state in
        # process memory. Finder is intentionally excluded here —
        # relaunchDesktopServices (DAG-ordered after writeBoundary) restarts it
        # via launchctl kickstart to preserve window state.
        ${daemonRefresh.refreshServicesMenu}
      '';
}
