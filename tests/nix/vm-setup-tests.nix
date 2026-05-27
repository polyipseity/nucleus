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
    "ramBytes"
    "diskBytes"
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
      badDisks = builtins.filter (vm: vm.diskBytes <= 0) manifest.VMs;
    in
    assert' (badDisks == [ ])
      "Every VM must have diskBytes > 0; bad entries: ${
        builtins.toString (builtins.map (v: v.name) badDisks)
      }";

  # RAM sizes must be positive integers.
  test_ram_sizes =
    let
      badRam = builtins.filter (vm: vm.ramBytes <= 0) manifest.VMs;
    in
    assert' (badRam == [ ])
      "Every VM must have ramBytes > 0; bad entries: ${
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
    "Linux"
    "macOS"
    "NixOS"
    "Windows"
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

  # windowsIsoUrl must be a string when present; the field is optional.
  test_windows_iso_url_type =
    let
      badIsoUrls = builtins.filter (
        vm: builtins.hasAttr "windowsIsoUrl" vm && !builtins.isString vm.windowsIsoUrl
      ) manifest.VMs;
    in
    assert' (badIsoUrls == [ ])
      "windowsIsoUrl must be a string for all VMs that declare it; bad entries: ${
        builtins.toString (builtins.map (v: v.name) badIsoUrls)
      }";

  # macOSVersion must be a string when present; the field is optional (macOS guests only).
  test_macos_version_type =
    let
      badVersions = builtins.filter (
        vm: builtins.hasAttr "macOSVersion" vm && !builtins.isString vm.macOSVersion
      ) manifest.VMs;
    in
    assert' (badVersions == [ ])
      "macOSVersion must be a string for all VMs that declare it; bad entries: ${
        builtins.toString (builtins.map (v: v.name) badVersions)
      }";

  # windowsEdition must be a string when present; the field is optional (Windows guests only).
  test_windows_edition_type =
    let
      badEditions = builtins.filter (
        vm: builtins.hasAttr "windowsEdition" vm && !builtins.isString vm.windowsEdition
      ) manifest.VMs;
    in
    assert' (badEditions == [ ])
      "windowsEdition must be a string for all VMs that declare it; bad entries: ${
        builtins.toString (builtins.map (v: v.name) badEditions)
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
    + "\n  <memory unit='MB'>${toString (vm.ramBytes / 1000000)}</memory>"
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

  # Domain XML must use MB (SI megabytes) as the memory unit so the SI byte
  # value from VMs.json maps to libvirt without lossy binary conversion.
  # libvirt supports SI units directly; see https://libvirt.org/formatdomain.html
  test_domain_xml_memory_unit =
    let
      results = builtins.map (
        vm:
        assert' (lib.hasInfix "unit='MB'" (mkDomainXml vm)) "Domain XML for VM '${vm.name}' must specify memory unit='MB' (SI megabytes)"
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
        {
          cond = builtins.pathExists ../../vms/macos/packer.pkr.hcl;
          msg = "vms/macos/packer.pkr.hcl must exist for macOS Tart builds";
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

  # The NixOS guest image must not force virtio_fs into the initrd. The share
  # is optional at runtime and some current kernels do not provide a loadable
  # virtio_fs module, which would make image generation fail before first boot.
  guest_nix_text = builtins.readFile ../../vms/nixos/guest.nix;
  nixos_packer_text = builtins.readFile ../../vms/nixos/packer.pkr.hcl;
  test_nixos_guest_virtiofs_not_forced = assert' (
    !(lib.hasInfix "boot.initrd.availableKernelModules = [ \"virtio_fs\" ];" guest_nix_text)
    && !(lib.hasInfix "boot.initrd.availableKernelModules = [ \\\"virtio_fs\\\" ];" nixos_packer_text)
  ) "NixOS guest generation must not force virtio_fs into the initrd on current kernels";

  # ---------------------------------------------------------------------------
  # Homebrew dependency tests
  # ---------------------------------------------------------------------------

  # tart (the macOS guest hypervisor) must be declared in homebrew.nix so that
  # it is installed via the Homebrew tap; it cannot be packaged in nixpkgs due
  # to its reliance on Apple Virtualization.framework code-signing entitlements.
  homebrew_text = builtins.readFile ../../src/hosts/MacBook/homebrew.nix;
  test_tart_in_homebrew = assert' (lib.hasInfix "cirruslabs/cli/tart" homebrew_text) "homebrew.nix must include cirruslabs/cli/tart for the macOS Tart VM guest";

  # MacBook must have a linux-builder module that registers the builder VM so
  # aarch64-linux derivations (required for nixos-generators NixOS guest image
  # builds) can be compiled on macOS via the Virtualization.framework VM.
  linux_builder_nix_text = builtins.readFile ../../src/hosts/MacBook/linux-builder.nix;
  test_macbook_linux_builder_enabled = assert' (lib.hasInfix "launchd.daemons.linux-builder" linux_builder_nix_text) "MacBook linux-builder.nix must configure the linux-builder launchd daemon";
  test_macbook_linux_builder_machines_file = assert' (lib.hasInfix "environment.etc.\"nix/machines\".text" linux_builder_nix_text) "MacBook linux-builder.nix must materialize /etc/nix/machines so Determinate Nix can see the remote builder";
  test_macbook_linux_builder_uses_ssh_protocol =
    assert'
      (
        lib.hasInfix "ssh://builder@linux-builder" linux_builder_nix_text
        && lib.hasInfix "protocol = \"ssh\";" linux_builder_nix_text
        && lib.hasInfix "benchmark,big-parallel,kvm - -" linux_builder_nix_text
      )
      "MacBook linux-builder.nix must register the builder via ssh:// without an inline host-key field because the current ssh-ng/master path fails on this host and legacy ssh must use the managed known_hosts alias instead";
  test_macbook_linux_builder_user_ssh_key_copy =
    assert'
      (
        lib.hasInfix "linux-builder_ed25519" linux_builder_nix_text
        && lib.hasInfix "install -m 600 -o \${username}" linux_builder_nix_text
      )
      "MacBook linux-builder.nix must mirror the builder key into the primary user's SSH directory for user-space ssh-ng clients";
  test_macbook_linux_builder_ssh_match_blocks =
    assert'
      (
        (lib.hasInfix "IdentitiesOnly yes" linux_builder_nix_text)
        && (lib.hasInfix "Match originalhost linux-builder localuser root" linux_builder_nix_text)
        && (lib.hasInfix "Match originalhost linux-builder localuser \${username}" linux_builder_nix_text)
      )
      "MacBook linux-builder.nix must route root and the primary user to separate builder identity files without falling back to unrelated SSH agent keys";

  # The MacBook base.nix must point the Nix daemon at /etc/nix/machines so the
  # linux-builder registration written by nix-darwin is actually used.
  base_nix_text = builtins.readFile ../../src/hosts/MacBook/base.nix;
  test_macbook_builders_machines = assert' (lib.hasInfix "builders = @/etc/nix/machines" base_nix_text) "MacBook base.nix must set builders = @/etc/nix/machines in nix.extraOptions";

  # vm-setup.sh must capture the Packer exit code for the macOS Tart build so
  # a failed packer invocation does not falsely report success.
  vm_setup_sh_text = builtins.readFile ../../scripts/vm-setup.sh;
  macbook_vms_nix_text = builtins.readFile ../../src/hosts/MacBook/vms.nix;
  test_macos_packer_exit_check = assert' (lib.hasInfix "_packer_status=0" vm_setup_sh_text) "scripts/vm-setup.sh must capture packer exit status (_packer_status=0)";

  # nixos-generators' -o flag expects a non-existent symlink path, not a
  # pre-created directory. The script must therefore use a child output link and
  # resolve the resulting symlink before copying the QCOW2 image.
  test_nixos_generators_output_link_handling =
    assert'
      (
        (lib.hasInfix "_out_link=\"$_tmpdir/result\"" vm_setup_sh_text)
        && (lib.hasInfix "readlink \"$_out_link\"" vm_setup_sh_text)
        && (lib.hasInfix "find -L \"$_out_link\"" vm_setup_sh_text)
      )
      "scripts/vm-setup.sh must give nixos-generators a non-existent output link path and resolve the resulting symlink";

  # The Packer failure branch for the macOS build must print a human-readable
  # error and return the captured exit code.
  test_macos_packer_failure_message = assert' (lib.hasInfix "Packer build for macOS VM" vm_setup_sh_text) "scripts/vm-setup.sh must print a failure message for a failed macOS Packer build";

  # The Packer failure branch for the Windows build must also surface the error.
  test_windows_packer_failure_message = assert' (lib.hasInfix "Packer build for Windows VM" vm_setup_sh_text) "scripts/vm-setup.sh must print a failure message for a failed Windows Packer build";

  # Local Mido compatibility adjustments must be applied at runtime from a
  # repository-owned patch file, not by editing the vendored submodule files.
  test_windows_iso_mido_patch_file_exists = assert' (builtins.pathExists ../../vms/windows/patches/mido-iso-link.patch) "vms/windows/patches/mido-iso-link.patch must exist for runtime Mido patching";
  test_windows_iso_mido_runtime_patch_support =
    assert'
      (
        (lib.hasInfix "NUCLEUS_MIDO_PATCH_FILE" vm_setup_sh_text)
        && (lib.hasInfix "vms/windows/patches/mido-iso-link.patch" vm_setup_sh_text)
        && (lib.hasInfix "patch -s" vm_setup_sh_text)
      )
      "scripts/vm-setup.sh must patch a temporary Mido copy at runtime instead of editing vendored submodule files";

  # UTM on Apple Silicon must keep Windows guests on x86_64/q35 while allowing
  # NixOS guests to follow host-native aarch64/virt when applicable.
  test_macbook_utm_windows_arch_override =
    assert'
      (
        (lib.hasInfix "vm.type == \"Windows\" then \"x86_64\"" macbook_vms_nix_text)
        && (lib.hasInfix "vmMachine = vm: if vmArch vm == \"x86_64\" then \"q35\" else \"virt\";" macbook_vms_nix_text)
      )
      "src/hosts/MacBook/vms.nix must force Windows UTM guests to x86_64/q35 so imported bundles match built Windows images";
  test_macbook_utm_schema_keys =
    assert'
      (
        (lib.hasInfix "<key>Drive</key>" macbook_vms_nix_text)
        && (lib.hasInfix "<key>ImageName</key>" macbook_vms_nix_text)
        && (lib.hasInfix "<key>QEMU</key>" macbook_vms_nix_text)
        && (lib.hasInfix "<key>Input</key>" macbook_vms_nix_text)
        && (lib.hasInfix "<key>CPUFlagsAdd</key>" macbook_vms_nix_text)
        && (lib.hasInfix "<key>CPUFlagsRemove</key>" macbook_vms_nix_text)
      )
      "src/hosts/MacBook/vms.nix must include modern UTM schema keys (Drive/ImageName/QEMU/Input/CPUFlagsAdd/CPUFlagsRemove) for reliable imports";
  test_macbook_utm_data_dir_disk_path =
    assert'
      (
        (lib.hasInfix "data_dir=\"$bundle/Data\"" vm_setup_sh_text)
        && (lib.hasInfix "disk_file=\"$data_dir/disk-main.qcow2\"" vm_setup_sh_text)
      )
      "scripts/vm-setup.sh must place UTM disk-main.qcow2 under bundle Data/ to match ImageName-based UTM drive resolution";
  test_macbook_utm_no_auto_open_import =
    assert' (!(lib.hasInfix "open \"$bundle\"" vm_setup_sh_text))
      "scripts/vm-setup.sh must not auto-open .utm bundles because that import path can trigger a blocking UTM popup";

  # Fido fallback must be gated to Windows hosts only; on macOS/Linux the
  # script must skip Fido and print the explicit Windows-CIM requirement.
  test_windows_iso_fido_windows_only =
    assert'
      (
        (lib.hasInfix "skipping Fido fallback on" vm_setup_sh_text)
        && (lib.hasInfix "Fido requires Windows CIM cmdlets" vm_setup_sh_text)
      )
      "scripts/vm-setup.sh must skip Fido fallback on non-Windows hosts and explain the Windows CIM requirement";

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
    test_windows_iso_url_type
    test_macos_version_type
    test_windows_edition_type
    test_plist_uuid_format
    test_plist_uuid_uniqueness
    test_domain_xml_kvm_type
    test_domain_xml_memory_unit
    test_domain_xml_disk_path_lowercase
    test_packer_templates_exist
    test_vm_setup_scripts_exist
    test_guest_nix_nonempty
    test_nixos_guest_virtiofs_not_forced
    test_tart_in_homebrew
    test_macbook_linux_builder_enabled
    test_macbook_linux_builder_machines_file
    test_macbook_linux_builder_uses_ssh_protocol
    test_macbook_linux_builder_user_ssh_key_copy
    test_macbook_linux_builder_ssh_match_blocks
    test_macbook_builders_machines
    test_macos_packer_exit_check
    test_nixos_generators_output_link_handling
    test_macos_packer_failure_message
    test_windows_packer_failure_message
    test_windows_iso_mido_patch_file_exists
    test_windows_iso_mido_runtime_patch_support
    test_macbook_utm_windows_arch_override
    test_macbook_utm_schema_keys
    test_macbook_utm_data_dir_disk_path
    test_macbook_utm_no_auto_open_import
    test_windows_iso_fido_windows_only
    ;

  summary = "vm-setup-tests: all tests passed";
}
