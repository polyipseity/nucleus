# modules/env/default.nix — Home Manager module for env var catalog.
#
# Registers the _nucleus.envVars option so the catalog is introspectable
# via config._nucleus.envVars in other modules.
{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  envLib = import ../lib/env-vars.nix {
    inherit
      config
      pkgs
      lib
      username
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
        macOSAllVars
        toJsonManifest
        getAllNixVarNames
        resolveValue
        defaultDevTools
        passwordStoreDir
        currentOs
        ;
    };
  };
}
