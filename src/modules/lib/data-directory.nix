# src/modules/lib/data-directory.nix — Centralized ~/data provisioning manifest.
#
# Defines system-level operations for the provision-data-directory.sh script.
# Each module that needs to create directories, files, or symlinks under ~/data
# adds its entries here. The manifest is consumed by the activation entry in
# home.nix.
#
# Invariant: the script only creates. It never deletes files, folders, or
# symlinks. If a target already exists, it is left untouched.
{
  lib,
  config,
  ...
}:
let
  homeDir = config.home.homeDirectory;

  # Base operations applied on every host. Apps add their entries via
  # lib.mkMerge in the config section.
  baseOps = [ ];

  # Hermes-agent SOUL.md provisioning. The persona file lives outside the
  # repo in ~/data/hermes-agent/ and is symlinked from ~/.hermes/SOUL.md.
  hermesOps = [
    {
      op = "dir";
      path = "hermes-agent";
    }
    {
      op = "file";
      path = "hermes-agent/SOUL.md";
      content = builtins.readFile ../configs/hermes-agent/SOUL.md;
    }
    {
      op = "symlink";
      path = "${homeDir}/.hermes/SOUL.md";
      target = "${homeDir}/data/hermes-agent/SOUL.md";
    }
  ];
in
{
  # The manifest is a list of operation attrsets. Each module appends its ops
  # via lib.mkMerge. The final merged list is passed to the shell script.
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
