# MacBook/services.nix — General macOS service configurations.
#
# Coordinates Automator workflow bundles (services/automator-workflows.nix) and
# App bundles (services/app-bundles.nix) deployment. This file handles shared
# daemon cache flush that runs after both sub-modules have deployed, so changes
# from both Automator workflows (NSServicesStatus) and App bundles
# (LaunchServices registration) take effect in one activation.
#
# For Automator workflows (.workflow bundles appearing in right-click →
# Quick Actions or menu bar → Services): see services/automator-workflows.nix
#
# For App bundles (.app bundles appearing in menu bar → Services):
# see services/app-bundles.nix
#
# Sorting policy — all service entry lists across both sub-modules are
# manually maintained in their declared order; no automatic re-sorting.
#   currentNucleusAppBundles: alphabetical by appDir.
#   currentNucleusWorkflows: alphabetical by entry name, with the 5 Optimize
#     PDF presets grouped as a block sorted quality-descending (default →
#     prepress → printer → ebook → screen). This is the cross-platform
#     convention (same on NixOS and Windows).
{ lib, pkgs, ... }:
let
  activationBundle = pkgs.callPackage ../../modules/lib/script-tree.nix { };
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
    ./services/automator-workflows.nix
    ./services/app-bundles.nix
  ];

  # Inject shared helpers into sub-modules.
  _module.args = { inherit mkPresentationModes; };

  # Shared cache flush that runs after both Automator workflows and App bundles
  # have been deployed. Each sub-module handles its own deploy and prune
  # lifecycle; this entry ensures final cache coherency.
  home.activation.deployNucleusServicesFlush =
    lib.hm.dag.entryAfter [ "deployNucleusAutomatorWorkflows" "macos-app-bundle-lib" ]
      ''
        # ── Phase 4: Flush daemon caches so changes take effect immediately ─
        # Without these restarts, cfprefsd and pbs hold stale cached state in
        # process memory. Finder is intentionally excluded here —
        # relaunchDesktopServices (DAG-ordered after writeBoundary) restarts it
        # via launchctl kickstart to preserve window state.
        "${activationBundle}/src/scripts/services/refresh-services-menu.sh"
      '';
}
