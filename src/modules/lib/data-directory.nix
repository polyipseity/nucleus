# src/modules/lib/data-directory.nix - Centralized ~/data provisioning manifest.
#
# Modules add their ~/data entries here and home.nix's activation entry passes
# the merged manifest to provision-data-directory.sh.
#
# Invariant: the script only creates. It never deletes, and an existing target
# is left untouched.
{
  lib,
  config,
  ...
}:
let
  homeDir = config.home.homeDirectory;

  baseOps = [ ];

  # All hermes state lives under ~/data.
  hermesOps = [
    {
      op = "dir";
      path = "hermes-agent";
    }
    {
      op = "symlink";
      path = "${homeDir}/.hermes";
      target = "${homeDir}/data/hermes-agent";
    }
  ];
in
{
  options.nucleus.dataDirectory.manifest = lib.mkOption {
    type = lib.types.listOf lib.types.attrs;
    default = [ ];
    description = "List of data-directory provisioning operations consumed by provision-data-directory.sh.";
  };

  config = {
    nucleus.dataDirectory.manifest = lib.mkMerge [
      baseOps
      hermesOps
    ];
  };
}
