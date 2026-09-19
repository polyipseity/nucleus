# MacBook/services/app-bundles.nix — macOS App bundles deployed via LaunchServices.
#
# These .app bundles appear in the Finder menu bar → Services. They are
# deployed to ~/Applications/ via LaunchServices registration.
# Less reliable than Quick Actions for context menu placement but work
# reliably in the Services menu.
#
# WHY: home.activation instead of home.file:
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
  # Currently deployed app bundles (via .app bundle mechanism).
  # Currently empty — all active services use Automator .workflow bundles.
  # Preserved as a wired-up mechanism for future use; entries may be added
  # here if a future service requires .app deployment.
  # Sorting policy: alphabetically by appDir (when list is non-empty).
  currentNucleusAppBundles = [ ];

  activationBundle = pkgs.callPackage ../../../../modules/lib/script-tree.nix { };

in
{
  # home.file for manual.md is now in automator-workflows.nix (where the
  # consuming workflow lives).

  # WHY: after macos-deploy-automator-workflows, not just linkGeneration.
  #   That step rewrites the whole NSServicesStatus dictionary in one shot,
  #   because `defaults -dict-add` rejects its workflow keys at parse time
  #   (parentheses are old-style plist array syntax, so those keys cannot be
  #   merged). A whole-dict write erases every other entry, and this step
  #   re-adds app-bundle entries with the merge-capable `-dict-add`, so the
  #   erase has to happen first. Siblings default to linkGeneration, where the
  #   attribute-name tie-break runs this step first and the entries are erased
  #   on every apply.
  home.activation.macos-deploy-app-bundles =
    lib.hm.dag.entryAfter [ "linkGeneration" "macos-deploy-automator-workflows" ]
      ''
        "${activationBundle}/src/hosts/MacBook/scripts/macos-deploy-app-bundles.sh" \
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
                source = "${svc.source}";
                presentationModesDict = mkPresentationModes svc.presentationModes;
              }) currentNucleusAppBundles
            )
          }'
      '';
}
