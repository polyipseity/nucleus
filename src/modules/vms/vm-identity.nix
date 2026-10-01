# src/modules/vms/vm-identity.nix: deterministic VM identity derivation.
#
# UUID and MAC are pure SHA-256 functions of the guest id, so re-provisioning
# reproduces the same identity and pack/unpack keeps it. Changing a guest id is a
# breaking identity change.
#
# The same derivation exists in shell (vm_mk_uuid/vm_mk_mac_address in
# src/scripts/lib/vm.sh) and PowerShell (Invoke-VMSetup.ps1); tests pin both
# twins against the vectors here.
let
  # 8-4-4-4-12 UUID from a SHA-256 hex digest.
  uuidFromDigest =
    h:
    "${builtins.substring 0 8 h}-${builtins.substring 8 4 h}-${builtins.substring 12 4 h}-${builtins.substring 16 4 h}-${builtins.substring 20 12 h}";
in
{
  # Deterministic UUID from the VM id.
  mkUuid = id: uuidFromDigest (builtins.hashString "sha256" id);

  # Locally-administered unicast MAC from the VM id, prefixed with the
  # manifest's macAddressPrefix.
  mkMacAddress =
    id: prefix:
    let
      h = builtins.hashString "sha256" "mac:${id}";
    in
    "${prefix}:${builtins.substring 0 2 h}:${builtins.substring 2 2 h}:${builtins.substring 4 2 h}:${builtins.substring 6 2 h}:${builtins.substring 8 2 h}";
}
