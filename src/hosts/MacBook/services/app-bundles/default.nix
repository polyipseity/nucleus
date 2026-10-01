# MacBook/services/app-bundles.nix: macOS App bundles deployed via LaunchServices.
#
# WHY: home.activation, not home.file. LaunchServices does not follow symlinks
# when it discovers Service provider bundles, so a home.file symlink into the
# store is invisible to it. Required Method 2 (read-only) case; see
# .agents/instructions/app-config-policy.instructions.md.
{
  lib,
  pkgs,
  mkPresentationModes,
  ...
}:
let
  # Empty for now: every active service uses an Automator .workflow bundle.
  # Sorting policy: alphabetically by appDir (when list is non-empty).
  currentNucleusAppBundles = [ ];

  activationBundle = pkgs.callPackage ../../../../modules/lib/script-tree.nix { };

in
{
  # home.file for manual.md is now in automator-workflows.nix (where the
  # consuming workflow lives).

  # WHY: after macos-deploy-automator-workflows, not just linkGeneration.
  #   That step rewrites the whole NSServicesStatus dictionary, because
  #   `defaults -dict-add` rejects old-style plist array syntax at parse time
  #   and so cannot merge those keys. The whole-dict write erases every other
  #   entry, so the app-bundle entries have to be re-added with `-dict-add`
  #   afterwards. Siblings default to linkGeneration, where the attribute-name
  #   tie-break orders this correctly.
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
