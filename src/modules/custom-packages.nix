# modules/custom-packages.nix — packages built from upstream git repositories.
#
# Builds tools directly from their git sources using Nix fetchers with pinned
# revisions.  Applies to all users (environment.systemPackages) on NixOS/macOS
# and per-user (home.packages) on standalone Home Manager.
#
# Adding a new custom package:
#   1. Add a derivation using pkgs.fetchFromGitHub + an appropriate builder.
#   2. Compute the SRI hash: nix-prefetch-url --unpack <tarball-url>
#   3. Add the derivation to the package list below.
{
  config,
  lib,
  pkgs,
  options,
  ...
}:

{
  config = lib.mkMerge [
    (lib.optionalAttrs (options ? environment && options.environment ? systemPackages) {
      environment.systemPackages = [
        # Add git-sourced packages here.
      ];
    })
    (lib.optionalAttrs (options ? home && options.home ? packages) {
      home.packages = [
        # Add git-sourced packages here.
      ];
    })
  ];
}
