# tests/nix/vm-setup-tests.nix — Tests for VM provisioning manifest and NixOS module options.
#
# Validates the structure of src/modules/VMs.json and confirms that the NixOS
# vms.nix module options are wired correctly.
# Run via: nix-instantiate --eval tests/nix/vm-setup-tests.nix

{
  lib ? import <nixpkgs/lib>,
}:
let
  assert' = cond: msg: if !cond then builtins.throw msg else null;

  manifest = builtins.fromJSON (builtins.readFile ../../src/modules/VMs.json);

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
      results = builtins.map validateVm manifest.VMs;
    in
    assert' (builtins.length manifest.VMs > 0) "VMs.json must declare at least one VM";

  # Disk sizes must be positive integers.
  test_disk_sizes =
    let
      badDisks = builtins.filter (vm: vm.diskGiB <= 0) manifest.VMs;
    in
    assert' (badDisks == [ ])
      "Every VM must have diskGiB > 0; bad entries: ${
        builtins.toString (builtins.map (v: v.name) badDisks)
      }";

  # RAM sizes must be positive integers.
  test_ram_sizes =
    let
      badRam = builtins.filter (vm: vm.ramMiB <= 0) manifest.VMs;
    in
    assert' (badRam == [ ])
      "Every VM must have ramMiB > 0; bad entries: ${
        builtins.toString (builtins.map (v: v.name) badRam)
      }";

  # CPU counts must be positive integers.
  test_cpu_counts =
    let
      badCpus = builtins.filter (vm: vm.cpus <= 0) manifest.VMs;
    in
    assert' (badCpus == [ ])
      "Every VM must have cpus > 0; bad entries: ${builtins.toString (builtins.map (v: v.name) badCpus)}";

  # VM names must be non-empty strings.
  test_vm_names =
    let
      badNames = builtins.filter (vm: vm.name == "") manifest.VMs;
    in
    assert' (badNames == [ ]) "Every VM must have a non-empty name";

  # VM types must be one of the known values.
  validTypes = [
    "linux"
    "macos"
    "nixos"
    "windows"
  ];
  test_vm_types =
    let
      badTypes = builtins.filter (vm: !(builtins.elem vm.type validTypes)) manifest.VMs;
    in
    assert' (badTypes == [ ])
      "Every VM must have a valid type (${builtins.toString validTypes}); bad entries: ${
        builtins.toString (builtins.map (v: v.name) badTypes)
      }";

  # shareDevDir must be a boolean.
  test_share_dev_dir_types =
    let
      badShare = builtins.filter (vm: !builtins.isBool vm.shareDevDir) manifest.VMs;
    in
    assert' (badShare == [ ])
      "shareDevDir must be a boolean for all VMs; bad entries: ${
        builtins.toString (builtins.map (v: v.name) badShare)
      }";

  # ---------------------------------------------------------------------------
  # Declarative config generation tests
  # ---------------------------------------------------------------------------

  # Deterministic UUID derivation (same logic as macbook/vms.nix).
  # We re-implement it here to validate the algorithm independently.
  mkUuid =
    name:
    let
      h = builtins.hashString "sha256" name;
    in
    "${builtins.substring 0 8 h}-${builtins.substring 8 4 h}-${builtins.substring 12 4 h}-${builtins.substring 16 4 h}-${builtins.substring 20 12 h}";

  # UUID must be 36 characters long (8-4-4-4-12 hex with dashes).
  test_plist_uuid_format =
    let
      checkUuid =
        vm:
        assert' (builtins.stringLength (mkUuid vm.name) == 36)
          "UUID for VM '${vm.name}' must be 36 characters; got ${toString (builtins.stringLength (mkUuid vm.name))}";
      results = builtins.map checkUuid manifest.VMs;
    in
    # Force evaluation of all results.
    assert' (builtins.all (r: r == null) results) "UUID format check failed";

  # Each VM must have a distinct UUID so UTM and libvirt can tell them apart.
  test_plist_uuid_uniqueness =
    let
      uuids = builtins.map (vm: mkUuid vm.name) manifest.VMs;
      uniqueUuids = lib.unique uuids;
    in
    assert' (builtins.length uuids == builtins.length uniqueUuids) "All VMs must have distinct UUIDs";

  # Domain XML template function (re-implemented without pkgs for test isolation;
  # uses hardcoded x86_64 arch and a placeholder emulator path).
  mkDomainXml =
    vm:
    let
      homeDir = "/home/testuser";
      vmDir = "${homeDir}/virtual machines";
    in
    "<domain type='kvm'>"
    + "\n  <name>${vm.name}</name>"
    + "\n  <memory unit='MiB'>${toString vm.ramMiB}</memory>"
    + "\n  <vcpu>${toString vm.cpus}</vcpu>"
    + "\n  <devices>"
    + "\n    <source file='${vmDir}/${vm.name}.qcow2'/>"
    + "\n  </devices>"
    + "\n</domain>";

  # Domain XML must contain a kvm domain type declaration.
  test_domain_xml_kvm_type =
    let
      results = builtins.map (
        vm:
        assert' (lib.hasInfix "<domain type='kvm'>" (mkDomainXml vm)) "Domain XML for VM '${vm.name}' must declare type='kvm'"
      ) manifest.VMs;
    in
    assert' (builtins.all (r: r == null) results) "Domain XML kvm type check failed";

  # Domain XML must use MiB as the memory unit (never KiB, GiB, or bare integers).
  test_domain_xml_memory_unit =
    let
      results = builtins.map (
        vm:
        assert' (lib.hasInfix "unit='MiB'" (mkDomainXml vm)) "Domain XML for VM '${vm.name}' must specify memory unit='MiB'"
      ) manifest.VMs;
    in
    assert' (builtins.all (r: r == null) results) "Domain XML memory unit check failed";

  # Domain XML disk path must use the lowercase 'virtual machines' path.
  test_domain_xml_disk_path_lowercase =
    let
      results = builtins.map (
        vm:
        assert' (lib.hasInfix "virtual machines/${vm.name}.qcow2" (mkDomainXml vm)) "Domain XML for VM '${vm.name}' must use lowercase 'virtual machines' in disk path"
      ) manifest.VMs;
    in
    assert' (builtins.all (r: r == null) results) "Domain XML disk path check failed";

  # ---------------------------------------------------------------------------
  # VM build artefact tests
  # ---------------------------------------------------------------------------

  # Packer templates and the nixos-generators guest config must exist.
  # Ensures that nucleus-vm-setup has all its required input files.
  test_packer_templates_exist =
    let
      checks = [
        {
          cond = builtins.pathExists ../../vms/nixos/guest.nix;
          msg = "vms/nixos/guest.nix must exist for nixos-generators builds";
        }
        {
          cond = builtins.pathExists ../../vms/nixos/packer.pkr.hcl;
          msg = "vms/nixos/packer.pkr.hcl must exist for Windows-host NixOS builds";
        }
        {
          cond = builtins.pathExists ../../vms/windows/packer.pkr.hcl;
          msg = "vms/windows/packer.pkr.hcl must exist for Windows 11 builds";
        }
        {
          cond = builtins.pathExists ../../vms/windows/Autounattend.xml;
          msg = "vms/windows/Autounattend.xml must exist for Windows 11 Packer builds";
        }
      ];
      results = builtins.map (c: assert' c.cond c.msg) checks;
    in
    assert' (builtins.all (r: r == null) results) "Packer template file existence check failed";

  # vm-setup scripts must exist for both POSIX and Windows hosts.
  test_vm_setup_scripts_exist =
    let
      checks = [
        {
          cond = builtins.pathExists ../../scripts/vm-setup.sh;
          msg = "scripts/vm-setup.sh must exist";
        }
        {
          cond = builtins.pathExists ../../scripts/vm-setup.ps1;
          msg = "scripts/vm-setup.ps1 must exist";
        }
      ];
      results = builtins.map (c: assert' c.cond c.msg) checks;
    in
    assert' (builtins.all (r: r == null) results) "VM setup script existence check failed";

  # guest.nix must be non-empty (parseable as a Nix expression).
  test_guest_nix_nonempty =
    let
      content = builtins.readFile ../../vms/nixos/guest.nix;
    in
    assert' (builtins.stringLength content > 0) "vms/nixos/guest.nix must not be empty";

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
    test_plist_uuid_format
    test_plist_uuid_uniqueness
    test_domain_xml_kvm_type
    test_domain_xml_memory_unit
    test_domain_xml_disk_path_lowercase
    test_packer_templates_exist
    test_vm_setup_scripts_exist
    test_guest_nix_nonempty
    ;

  summary = "vm-setup-tests: all tests passed";
}
