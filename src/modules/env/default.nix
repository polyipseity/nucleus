# modules/env/default.nix — Home Manager module for env var catalog.
#
# Registers the _nucleus.envVars option so the catalog is introspectable
# via config._nucleus.envVars in other modules.
{
  config,
  lib,
  pkgs,
  username,
  hostName,
  ...
}:
let
  managedPaths = import ../lib/managed-paths.nix { inherit pkgs; };
  envLib = import ../lib/env-catalog.nix {
    inherit
      config
      pkgs
      lib
      username
      hostName
      ;
  };
in
{
  options._nucleus.envVars = lib.mkOption {
    type = lib.types.attrs;
    internal = true;
    description = "Catalog of all managed environment variables (Nix side).";
    default = envLib.catalog;
  };

  options._nucleus.envVarsHelpers = lib.mkOption {
    type = lib.types.attrs;
    internal = true;
    description = "Helper functions for transforming the env var catalog.";
    default = {
      inherit (envLib)
        allVars
        systemVars
        macBookAllVars
        toJsonManifest
        getAllNixVarNames
        resolveValue
        ;
      inherit (managedPaths)
        defaultDevTools
        ;
      inherit (envLib)
        passwordStoreDir
        currentHost
        ;
    };
  };
}
