# MacBook/services.nix - shared daemon cache flush that runs after both the
# Automator workflow and App bundle sub-modules deploy, so NSServicesStatus and
# LaunchServices changes take effect in one activation.
#
# Sorting policy: both sub-modules keep their entry lists by hand, no automatic
# re-sorting. currentNucleusAppBundles is alphabetical by appDir;
# currentNucleusWorkflows is alphabetical by entry name with the 5 Optimize PDF
# presets grouped and numbered quality-descending so bundle directory names sort
# correctly. Same convention on NixOS and Windows.
{ lib, pkgs, ... }:
let
  activationBundle = pkgs.callPackage ../../../modules/lib/script-tree.nix { };
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
    ./automator-workflows
    ./app-bundles
  ];

  # Inject shared helpers into sub-modules.
  _module.args = { inherit mkPresentationModes; };

  # Runs after both sub-modules deploy, including the forced pbs rescan that
  # makes renamed or pruned workflows visible without a logout.
  home.activation.macos-flush-services-cache =
    lib.hm.dag.entryAfter [ "macos-deploy-automator-workflows" "macos-deploy-app-bundles" ]
      ''
        "${activationBundle}/src/scripts/services/refresh-services-menu.sh" \
          "/System/Library/CoreServices/pbs" \
          "/bin/launchctl" \
          "/usr/bin/sudo"
      '';
}
