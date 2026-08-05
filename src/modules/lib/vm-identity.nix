# src/modules/lib/vm-identity.nix — deterministic VM identity derivation.
#
# The UUID and MAC address of a guest are pure SHA-256 functions of the guest
# id, so re-provisioning the same VM always reproduces the same identity and a
# payload copied to another machine keeps its identity (pack/unpack). Changing
# a guest's id is a breaking identity change.
#
# The same derivation is re-implemented in shell (vm_mk_uuid/vm_mk_mac_address
# in src/scripts/lib/vm.sh) and PowerShell (src/hosts/Windows/modules/system/
# Invoke-VMSetup.ps1); tests pin both twins against the known vectors here
# (tests/modules/vm-setup-tests.nix and tests/scripts/vm-disk-model-tests.sh).
let
  # Format a SHA-256 hex digest as an 8-4-4-4-12 UUID.
  uuidFromDigest =
    h:
    "${builtins.substring 0 8 h}-${builtins.substring 8 4 h}-${builtins.substring 12 4 h}-${builtins.substring 16 4 h}-${builtins.substring 20 12 h}";
in
{
  # Derive a deterministic UUID from the VM id (format: 8-4-4-4-12 hex).
  mkUuid = id: uuidFromDigest (builtins.hashString "sha256" id);

  # Derive a deterministic locally-administered unicast MAC from the VM id,
  # with the prefix taken from the manifest's macAddressPrefix field.
  mkMacAddress =
    id: prefix:
    let
      h = builtins.hashString "sha256" "mac:${id}";
    in
    "${prefix}:${builtins.substring 0 2 h}:${builtins.substring 2 2 h}:${builtins.substring 4 2 h}:${builtins.substring 6 2 h}:${builtins.substring 8 2 h}";
}
