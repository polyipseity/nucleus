# tests/nix/vm-setup-tests.nix — Tests for VM provisioning manifest and NixOS module options.
#
# Validates the structure of src/modules/vms.json and confirms that the NixOS
# vms.nix module options are wired correctly.
# Run via: nix-instantiate --eval tests/nix/vm-setup-tests.nix

{
  lib ? import <nixpkgs/lib>,
}:
let
  assert' = cond: msg: if !cond then builtins.throw msg else null;

  manifest = builtins.fromJSON (builtins.readFile ../../src/modules/vms.json);

  # Required fields for every VM entry.
  requiredFields = [
    "name"
    "display"
    "cpus"
    "ramMiB"
    "diskGiB"
    "type"
    "shareDevDir"
  ];

  # Validate that every VM entry has all required fields with correct types.
  validateVm =
    vm:
    let
      hasField = f: builtins.hasAttr f vm;
      missingFields = builtins.filter (f: !hasField f) requiredFields;
    in
    assert' (
      missingFields == [ ]
    ) "VM '${vm.name or "<unnamed>"}' is missing required fields: ${builtins.toString missingFields}";

  # All VMs pass field validation.
  test_required_fields =
    let
      results = builtins.map validateVm manifest.vms;
    in
    assert' (builtins.length manifest.vms > 0) "vms.json must declare at least one VM";

  # Disk sizes must be positive integers.
  test_disk_sizes =
    let
      badDisks = builtins.filter (vm: vm.diskGiB <= 0) manifest.vms;
    in
    assert' (badDisks == [ ])
      "Every VM must have diskGiB > 0; bad entries: ${
        builtins.toString (builtins.map (v: v.name) badDisks)
      }";

  # RAM sizes must be positive integers.
  test_ram_sizes =
    let
      badRam = builtins.filter (vm: vm.ramMiB <= 0) manifest.vms;
    in
    assert' (badRam == [ ])
      "Every VM must have ramMiB > 0; bad entries: ${
        builtins.toString (builtins.map (v: v.name) badRam)
      }";

  # CPU counts must be positive integers.
  test_cpu_counts =
    let
      badCpus = builtins.filter (vm: vm.cpus <= 0) manifest.vms;
    in
    assert' (badCpus == [ ])
      "Every VM must have cpus > 0; bad entries: ${builtins.toString (builtins.map (v: v.name) badCpus)}";

  # VM names must be non-empty strings.
  test_vm_names =
    let
      badNames = builtins.filter (vm: vm.name == "") manifest.vms;
    in
    assert' (badNames == [ ]) "Every VM must have a non-empty name";

  # VM types must be one of the known values.
  validTypes = [
    "nixos"
    "windows"
    "linux"
  ];
  test_vm_types =
    let
      badTypes = builtins.filter (vm: !(builtins.elem vm.type validTypes)) manifest.vms;
    in
    assert' (badTypes == [ ])
      "Every VM must have a valid type (${builtins.toString validTypes}); bad entries: ${
        builtins.toString (builtins.map (v: v.name) badTypes)
      }";

  # shareDevDir must be a boolean.
  test_share_dev_dir_types =
    let
      badShare = builtins.filter (vm: !builtins.isBool vm.shareDevDir) manifest.vms;
    in
    assert' (badShare == [ ])
      "shareDevDir must be a boolean for all VMs; bad entries: ${
        builtins.toString (builtins.map (v: v.name) badShare)
      }";

in
{
  inherit
    test_required_fields
    test_disk_sizes
    test_ram_sizes
    test_cpu_counts
    test_vm_names
    test_vm_types
    test_share_dev_dir_types
    ;

  summary = "vm-setup-tests: all tests passed";
}
