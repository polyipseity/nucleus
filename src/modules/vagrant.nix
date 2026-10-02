# Vagrant plugin registration under the managed VAGRANT_HOME.
#
# The provider gems come from the store through the wrapper built in
# lib/vagrant-plugins.nix. Vagrant still needs a registry entry per plugin in
# $VAGRANT_HOME/plugins.json, which this module writes and then verifies, so a
# plugin that fails to load surfaces as a failed activation instead of a
# missing provider much later.
{
  hostName,
  lib,
  pkgs,
  username,
  ...
}:
let
  plugins = import ./lib/vagrant-plugins.nix { inherit lib pkgs; };

  activationBundle = pkgs.callPackage ./lib/script-tree.nix { };

  vagrantHome =
    (import ./lib/env-secrets.nix {
      inherit
        lib
        pkgs
        username
        hostName
        ;
    }).resolveValue
      "VAGRANT_HOME"
      hostName;
in
{
  # WHY after linkGeneration: the wrapper is linked by then, so the check runs
  # the same `vagrant` the user gets.
  home.activation.install-vagrant-plugins = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    "${activationBundle}/src/scripts/packages/install-vagrant-plugins.sh" \
      "${plugins.package}/bin/vagrant" \
      "${pkgs.jq}/bin/jq" \
      "${vagrantHome}" \
      '${builtins.toJSON plugins.registry}'
  '';
}
