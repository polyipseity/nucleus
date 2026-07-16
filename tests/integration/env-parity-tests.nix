# tests/integration/env-parity-tests.nix — Catalog manifest for Windows parity.
#
# Evaluates the centralized env var catalog and builds a manifest for the
# Windows Pester test to verify DSC and profile env var parity.
#
# Standalone expression: import directly, no function wrapper needed.
# The Windows Pester test accesses via (import "...").manifest (no arg).
let
  lib = import <nixpkgs/lib>;
  pkgs = import <nixpkgs> { };
  config = { };

  envVars = import ../../src/modules/lib/env-catalog.nix {
    inherit config pkgs lib;
    username = "test";
  };

  # Build manifest directly from catalog, avoiding toJSON/fromJSON round-trip.
  # (builtins.fromJSON chokes on toJsonManifest output due to a Nix eval issue.)
  manifest = builtins.map (
    name:
    let
      entry = envVars.catalog.${name};
    in
    {
      inherit name;
      hasNixOsEntry = entry.values ? NixOS || entry.values ? default;
      hasWindowsEntry = entry.values ? Windows || entry.values ? default;
      hasMacOsEntry = entry.values ? macOS || entry.values ? default;
      nixosValue = envVars.resolveValue name "NixOS";
      macosValue = envVars.resolveValue name "macOS";
      windowsValue = envVars.resolveValue name "Windows";
      userSpecific = entry ? userSpecific && entry.userSpecific;
      why = entry.why;
    }
  ) envVars.getAllNixVarNames;

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
in
{
  inherit
    manifest
    nixosVars
    windowsRequiredVarNames
    profileOnlyVarNames
    applyOnlyVarNames
    dscVarNames
    ;
}
