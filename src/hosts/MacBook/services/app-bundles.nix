# MacBook/services/app-bundles.nix — macOS App bundles deployed via LaunchServices.
#
# !!! WARNING: DO NOT DELETE THIS MODULE, THE current/removed LISTS, OR THE
# !!! DEPLOY MECHANISM. The self-pruning framework (Phase 1a + Phase 2) is the
# !!! only way to cleanly remove historically-deployed .app bundles and their
# !!! NSServicesStatus keys from disk. Deleting this module leaves orphaned
# !!! NSServicesStatus keys in pbs.plist and stale .app directories in
# !!! ~/Applications/. If you are tempted to delete this file, STOP and read
# !!! the full comment. — past agent
#
# These .app bundles appear in the Finder menu bar → Services. They are
# deployed to ~/Applications/ via LaunchServices registration.
# Less reliable than Quick Actions for context menu placement but work
# reliably in the Services menu.
#
# WHY home.activation instead of home.file:
#   home.file creates a symlink to the Nix store, but macOS LaunchServices
#   does not traverse symlinks when discovering Service provider .app
#   bundles. This is a required Method 2 (read-only deployment) case;
#   see .agents/instructions/app-config-policy.instructions.md.
#   A home.activation script that deploys the .app on each generation
#   switch guarantees LaunchServices can find it.
{
  lib,
  pkgs,
  mkPresentationModes,
  ...
}:
let
  # Known list of historically-removed Nucleus app bundles.
  # When a bundle is removed, add its metadata here and remove its app dir.
  # The activation script unconditionally removes its NSServicesStatus key
  # and prunes its app directory from disk. Entries can be removed after all
  # machines have applied once after the removal commit.
  removedNucleusAppBundles = [
    # Old pre-per-preset single .app bundle (replaced by per-preset Automator
    # workflows).
    {
      appDir = "NucleusGSPDFOpt.app";
      bundleId = "com.nucleus.GSPDFOpt";
      menuItem = "gs optimize pdf";
      message = "open";
    }
    # Moved from .app bundle to Automator .workflow (see automator-workflows.nix).
    {
      appDir = "NucleusManual.app";
      bundleId = "com.nucleus.OpenNucleusManual";
      menuItem = "open nucleus manual";
      message = "open";
    }
  ];

  # Currently deployed app bundles (via .app bundle mechanism).
  # Currently empty — all active services use Automator .workflow bundles.
  # Preserved as a wired-up mechanism for future use; entries may be added
  # here if a future service requires .app deployment.
  # Sorting policy: alphabetically by appDir (when list is non-empty).
  currentNucleusAppBundles = [ ];

  activationBundle = pkgs.callPackage ../../../modules/lib/script-tree.nix { };

in
{
  # home.file for manual.md is now in automator-workflows.nix (where the
  # consuming workflow lives).

  home.activation.macos-deploy-app-bundles = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    "${activationBundle}/src/scripts/hosts/MacBook/macos-deploy-app-bundles.sh" \
      "${pkgs.jq}/bin/jq" \
      '${
        builtins.toJSON (
          map (svc: {
            inherit (svc)
              appDir
              bundleId
              menuItem
              message
              ;
          }) removedNucleusAppBundles
        )
      }' \
      '${
        builtins.toJSON (
          map (svc: {
            inherit (svc)
              appDir
              bundleId
              menuItem
              message
              ;
            source = "${svc.source}";
            presentationModesDict = mkPresentationModes svc.presentationModes;
          }) currentNucleusAppBundles
        )
      }'
  '';
}
