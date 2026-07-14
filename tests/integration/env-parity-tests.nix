# tests/integration/env-parity-tests.nix — Catalog manifest for Windows parity.
#
# Evaluates the centralized env var catalog and outputs a JSON manifest of
# every variable that has a NixOS or Windows entry.  The Windows Pester test
# consumes this to verify DSC and profile env var parity.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  envVars = import ../../modules/lib/env-vars.nix { inherit config pkgs lib; };
in
{
  # Full manifest of all vars in the catalog.
  manifest = builtins.fromJSON envVars.toJsonManifest;

  # Subset of vars that have a NixOS entry (should map to a DSC entry).
  nixosVars = builtins.filter (v: v.hasNixOsEntry) manifest;

  # Names of vars that must exist in Windows env.dsc.yml.
  windowsRequiredVarNames = builtins.filter (
    name:
    name != "NUCLEUS_REPO_ROOT"
    && name != "DEVELOPER_DIR"
    && name != "SDKROOT"
    && name != "LIBRARY_PATH"
    && name != "NIX_SSL_CERT_FILE"
  ) envVars.getAllNixVarNames;

  # Vars that Windows sets via Sync-ShellProfile.ps1 instead of DSC.
  profileOnlyVarNames = [ ];

  # Vars that Windows sets via apply.ps1 instead of DSC (also in system/env.dsc.yml).
  applyOnlyVarNames = [ "NUCLEUS_HOST" ];

  # Vars that should be in DSC.
  dscVarNames = builtins.filter (
    name: !builtins.elem name (profileOnlyVarNames ++ applyOnlyVarNames)
  ) windowsRequiredVarNames;
}
