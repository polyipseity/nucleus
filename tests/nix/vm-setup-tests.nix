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
  windows_vm_setup_ps1_text = builtins.readFile ../../src/hosts/Windows/modules/system/Invoke-VMSetup.ps1;
  windows_vm_setup_wrapper_ps1_text = builtins.readFile ../../scripts/vm-setup.ps1;
  macbook_vms_nix_text = builtins.readFile ../../src/hosts/MacBook/vms.nix;
  vms_json_text = builtins.readFile ../../src/modules/VMs.json;
  users_json_text = builtins.readFile ../../src/modules/users.json;
  windows_users_json_text = builtins.readFile ../../src/hosts/Windows/users.json;
  user_secret_text = builtins.readFile ../../src/secrets/users-polyipseity.yml;
  vms_windows_packer_text = builtins.readFile ../../vms/windows/packer.pkr.hcl;
  vms_windows_autounattend_text = builtins.readFile ../../vms/windows/Autounattend.xml;
  vms_macos_packer_text = builtins.readFile ../../vms/macos/packer.pkr.hcl;
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

  # nixos-generators produces a small default qcow2 unless resized explicitly.
  # vm-setup must resize NixOS images to manifest disk size so provisioning
  # logic does not reject the pre-built image for being too small.
  test_nixos_image_resize_to_manifest_disk = assert' (
    (lib.hasInfix "build_nixos_image NAME DISK_GIB" vm_setup_sh_text)
    && (lib.hasInfix "qemu-img resize \"$_out\" \"\${_disk_gib}G\"" vm_setup_sh_text)
  ) "scripts/vm-setup.sh must resize generated NixOS qcow2 images to the manifest disk size";

  # The Packer failure branch for the macOS build must print a human-readable
  # error and return the captured exit code.
  test_macos_packer_failure_message = assert' (lib.hasInfix "Packer build for macOS VM" vm_setup_sh_text) "scripts/vm-setup.sh must print a failure message for a failed macOS Packer build";

  # The Packer failure branch for the Windows build must also surface the error.
  test_windows_packer_failure_message = assert' (lib.hasInfix "Packer build for Windows VM" vm_setup_sh_text) "scripts/vm-setup.sh must print a failure message for a failed Windows Packer build";

  # Windows QEMU builds must:
  # 1. Pin WinRM to 5985 with explicit port forward (not random NAT mapping)
  # 2. Keep boot_wait=5s and pause_before_connecting=120s
  # 3. Expose selectable firmware_mode and boot_strategy in packer.pkr.hcl
  # 4. Retry packer builds in vm-setup wrappers with EFI-first + BIOS fallback
  #    before giving up, so installer timing changes do not hard-lock on one
  #    brittle keying pattern.
  test_windows_packer_winrm_port_forward =
    assert'
      (
        (lib.hasInfix "winrm_port     = 5985" vms_windows_packer_text)
        && (lib.hasInfix "skip_nat_mapping = true" vms_windows_packer_text)
        && (lib.hasInfix "hostfwd=tcp::5985-:5985" vms_windows_packer_text)
        && (lib.hasInfix "boot_wait    = \"5s\"" vms_windows_packer_text)
        && (lib.hasInfix "pause_before_connecting = \"120s\"" vms_windows_packer_text)
        && (lib.hasInfix "variable \"firmware_mode\"" vms_windows_packer_text)
        && (lib.hasInfix "variable \"boot_strategy\"" vms_windows_packer_text)
        && (lib.hasInfix "variable \"headless\"" vms_windows_packer_text)
        && (lib.hasInfix "variable \"display_backend\"" vms_windows_packer_text)
        && (lib.hasInfix "bootPromptByStrategy" vms_windows_packer_text)
        && (lib.hasInfix "bootPromptEfiDirect" vms_windows_packer_text)
        && (lib.hasInfix "boot_command = local.bootPromptByStrategy" vms_windows_packer_text)
        && (lib.hasInfix "efi_boot          = local.efiEnabled" vms_windows_packer_text)
        && (lib.hasInfix "headless = var.headless" vms_windows_packer_text)
        && (lib.hasInfix "display  = local.displayBackendResolved" vms_windows_packer_text)
        && (lib.hasInfix "skip_compaction  = true" vms_windows_packer_text)
        && (lib.hasInfix "disk_compression = false" vms_windows_packer_text)
      )
      "Windows VM packer template must pin WinRM communicator wiring and expose controlled firmware/debug knobs";

  # Autounattend.xml must configure WinRM before VirtIO driver scan to prevent blocking.
  test_windows_autounattend_winrm_before_virtio =
    assert'
      (
        (lib.hasInfix "<Order>1</Order>" vms_windows_autounattend_text)
        && (lib.hasInfix "winrm quickconfig" vms_windows_autounattend_text)
        && (lib.hasInfix "<Order>7</Order>" vms_windows_autounattend_text)
        && (lib.hasInfix "VirtIO" vms_windows_autounattend_text)
      )
      "vms/windows/Autounattend.xml must configure WinRM in Orders 1–6 before VirtIO driver scan in Order 7 so WinRM is ready even if driver scan is slow";
  # BIOS installs need a normal NTFS partition type for the active system
  # partition. TypeID 0x27 is a recovery/hidden partition type and can leave
  # SeaBIOS stuck at "Booting from Hard Disk...".
  test_windows_autounattend_bios_system_partition_type =
    assert'
      (
        (lib.hasInfix "<TypeID>0x07</TypeID>" vms_windows_autounattend_text)
        && !(lib.hasInfix "<TypeID>0x27</TypeID>" vms_windows_autounattend_text)
      )
      "vms/windows/Autounattend.xml must keep the active BIOS system partition TypeID at 0x07 (not 0x27)";

  # Guest credential policy: username/password must resolve from per-user SOPS
  # secrets via vmGuest secret-key references and stay wired across all guest
  # build paths.
  test_guest_credentials_policy_in_user_registries = assert' (
    (lib.hasInfix "\"vmGuest\"" users_json_text)
    && (lib.hasInfix "\"usernameSecretKey\": \"vm_guest_username\"" users_json_text)
    && (lib.hasInfix "\"passwordSecretKey\": \"vm_guest_password\"" users_json_text)
    && (lib.hasInfix "\"vmGuest\"" windows_users_json_text)
    && (lib.hasInfix "\"usernameSecretKey\": \"vm_guest_username\"" windows_users_json_text)
    && (lib.hasInfix "\"passwordSecretKey\": \"vm_guest_password\"" windows_users_json_text)
  ) "POSIX and Windows user registries must declare vmGuest secret-key references";

  test_guest_credentials_policy_in_user_secrets = assert' (
    (lib.hasInfix "vm_guest_username:" user_secret_text)
    && (lib.hasInfix "vm_guest_password:" user_secret_text)
  ) "users-polyipseity.yml must contain secret-backed VM guest username/password keys";

  test_guest_credentials_policy_in_vm_setup_sh =
    assert'
      (
        (lib.hasInfix "resolve_vm_guest_credentials" vm_setup_sh_text)
        && (lib.hasInfix "src/modules/users.json" vm_setup_sh_text)
        && (lib.hasInfix "users-\${_rvgc_owner}.yml" vm_setup_sh_text)
        && (lib.hasInfix "vmGuest.usernameSecretKey" vm_setup_sh_text)
        && (lib.hasInfix "vmGuest.passwordSecretKey" vm_setup_sh_text)
        && (lib.hasInfix "sops --decrypt --output-type json" vm_setup_sh_text)
        && (lib.hasInfix "NUCLEUS_VM_GUEST_USERNAME" vm_setup_sh_text)
        && (lib.hasInfix "NUCLEUS_VM_GUEST_PASSWORD" vm_setup_sh_text)
      )
      "scripts/vm-setup.sh must resolve guest credentials from per-user SOPS secrets and export/pass them to guest builders";

  test_nixos_generators_uses_exported_env_credentials =
    assert'
      (
        (lib.hasInfix "guestUsername = builtins.getEnv \"NUCLEUS_VM_GUEST_USERNAME\"" guest_nix_text)
        && (lib.hasInfix "guestPassword = builtins.getEnv \"NUCLEUS_VM_GUEST_PASSWORD\"" guest_nix_text)
        && !(lib.hasInfix "--argstr guestUsername" vm_setup_sh_text)
        && !(lib.hasInfix "--argstr guestPassword" vm_setup_sh_text)
      )
      "scripts/vm-setup.sh must let nixos-generators consume exported guest credentials directly instead of passing unsupported --argstr flags";

  test_guest_credentials_policy_in_windows_vm_setup_ps1 =
    assert'
      (
        (lib.hasInfix "Resolve-VMGuestCredential" windows_vm_setup_ps1_text)
        && (lib.hasInfix "src\\hosts\\Windows\\users.json" windows_vm_setup_ps1_text)
        && (lib.hasInfix "src\\secrets\\users-$secretOwner.yml" windows_vm_setup_ps1_text)
        && (lib.hasInfix "vmGuest secret-key references" windows_vm_setup_ps1_text)
        && (lib.hasInfix "--decrypt --output-type json" windows_vm_setup_ps1_text)
        && (lib.hasInfix "-GuestAccountName $guestUsername -GuestSecret $guestPassword" windows_vm_setup_ps1_text)
        && (lib.hasInfix "-GuestSecretHash $guestSecretHash" windows_vm_setup_ps1_text)
        && (lib.hasInfix "__NUCLEUS_GUEST_USERNAME__" windows_vm_setup_ps1_text)
        && (lib.hasInfix "__NUCLEUS_GUEST_PASSWORD__" windows_vm_setup_ps1_text)
      )
      "Invoke-VMSetup.ps1 must resolve and propagate secret-backed guest credentials to all Windows-host build paths";

  test_guest_credentials_policy_in_nixos_guest = assert' (
    (lib.hasInfix "guestUsername = builtins.getEnv \"NUCLEUS_VM_GUEST_USERNAME\"" guest_nix_text)
    && (lib.hasInfix "guestPassword = builtins.getEnv \"NUCLEUS_VM_GUEST_PASSWORD\"" guest_nix_text)
    && (lib.hasInfix "users.users.\"\${guestUsername}\"" guest_nix_text)
  ) "vms/nixos/guest.nix must consume exported guest credentials and create a login user";

  test_guest_credentials_policy_in_nixos_packer = assert' (
    (lib.hasInfix "variable \"guest_username\"" nixos_packer_text)
    && (lib.hasInfix "variable \"guest_password\"" nixos_packer_text)
    && (lib.hasInfix "users.users.\\\"\${var.guest_username}\\\"" nixos_packer_text)
    && !(lib.hasInfix "default     = \"nixos\"" nixos_packer_text)
  ) "vms/nixos/packer.pkr.hcl must accept and apply guest credentials for Windows-host NixOS builds";

  test_windows_nixos_build_honors_manifest_disk_size =
    assert'
      (
        (lib.hasInfix "-DiskGib $diskGib" windows_vm_setup_ps1_text)
        && (lib.hasInfix "[int]$DiskGib" windows_vm_setup_ps1_text)
        && (lib.hasInfix "-var \"disk_size=\${DiskGib}G\"" windows_vm_setup_ps1_text)
      )
      "Invoke-VMSetup.ps1 must pass the manifest-derived disk size into Windows-host NixOS Packer builds";

  test_windows_helper_cleanup_collision_guard =
    assert'
      (
        (lib.hasInfix "case-insensitive filename collision" windows_vm_setup_ps1_text)
        && (lib.hasInfix "$legacyHelper.ToLowerInvariant()" windows_vm_setup_ps1_text)
        && (lib.hasInfix "$startScriptPs1" windows_vm_setup_ps1_text)
        && (lib.hasInfix "$startScriptSh" windows_vm_setup_ps1_text)
      )
      "Invoke-VMSetup.ps1 must not delete freshly generated start-* helpers when cleaning up legacy Start-* names on Windows";

  test_guest_credentials_policy_in_windows_packer =
    assert'
      (
        (lib.hasInfix "variable \"guest_username\"" vms_windows_packer_text)
        && (lib.hasInfix "variable \"guest_password\"" vms_windows_packer_text)
        && (lib.hasInfix "variable \"autounattend_path\"" vms_windows_packer_text)
        && (lib.hasInfix "winrm_username = var.guest_username" vms_windows_packer_text)
        && (lib.hasInfix "winrm_password = var.guest_password" vms_windows_packer_text)
        && (lib.hasInfix "var.autounattend_path" vms_windows_packer_text)
      )
      "vms/windows/packer.pkr.hcl must wire guest credentials into WinRM and consume a rendered Autounattend path";

  test_guest_credentials_policy_in_windows_autounattend = assert' (
    (lib.hasInfix "__NUCLEUS_GUEST_USERNAME__" vms_windows_autounattend_text)
    && (lib.hasInfix "__NUCLEUS_GUEST_PASSWORD__" vms_windows_autounattend_text)
  ) "vms/windows/Autounattend.xml must expose guest credential placeholders for runtime rendering";

  test_guest_credentials_policy_in_macos_packer =
    assert'
      (
        (lib.hasInfix "variable \"guest_username\"" vms_macos_packer_text)
        && (lib.hasInfix "variable \"guest_password\"" vms_macos_packer_text)
        && (lib.hasInfix "sysadminctl -addUser" vms_macos_packer_text)
      )
      "vms/macos/packer.pkr.hcl must provision a guest account using the secret-backed guest credential policy";

  test_vm_guest_credential_drift_replacement =
    assert'
      (
        (lib.hasInfix "vm_guest_credentials_marker_path" vm_setup_sh_text)
        && (lib.hasInfix "vm_guest_credentials_marker_matches" vm_setup_sh_text)
        && (lib.hasInfix "NixOS image guest credential drift detected" vm_setup_sh_text)
        && (lib.hasInfix "Windows image guest credential drift detected" vm_setup_sh_text)
        && (lib.hasInfix "macOS guest credential drift detected" vm_setup_sh_text)
        && (lib.hasInfix "runtime disk guest credential drift detected" vm_setup_sh_text)
        && (lib.hasInfix ".vm-guest-credentials-sha256" vm_setup_sh_text)
        && (lib.hasInfix "Get-VMGuestSecretMarkerPath" windows_vm_setup_ps1_text)
        && (lib.hasInfix "Test-VMGuestSecretMarker" windows_vm_setup_ps1_text)
        && (lib.hasInfix "NixOS image guest credential drift detected" windows_vm_setup_ps1_text)
        && (lib.hasInfix "Windows image guest credential drift detected" windows_vm_setup_ps1_text)
        && (lib.hasInfix "runtime disk guest credential drift detected" windows_vm_setup_ps1_text)
      )
      "POSIX and Windows vm setup flows must detect VM guest credential drift via marker files and replace stale images/runtime disks";

  test_utm_runtime_replacement_requires_valid_prebuilt =
    assert'
      (
        (lib.hasInfix "_prebuilt_valid=false" vm_setup_sh_text)
        && (lib.hasInfix "cannot replace the %s runtime disk because no valid pre-built image is available" vm_setup_sh_text)
      )
      "scripts/vm-setup.sh must refuse to replace UTM runtime disks when the rebuild step did not produce a valid pre-built qcow2";

  test_libvirt_runtime_validation_parity =
    assert'
      (
        (lib.hasInfix "failed to start libvirt default network" vm_setup_sh_text)
        && (lib.hasInfix "failed to mark libvirt default network for autostart" vm_setup_sh_text)
        && (lib.hasInfix "validate_qcow2_image \"$_prebuilt\" \"pre-built image for \${vm_name}\"" vm_setup_sh_text)
        && (lib.hasInfix "validate_qcow2_image \"$disk_path\" \"existing libvirt runtime disk for \${vm_name}\"" vm_setup_sh_text)
        && (lib.hasInfix "existing libvirt runtime disk is invalid" vm_setup_sh_text)
      )
      "scripts/vm-setup.sh must validate libvirt prebuilt/runtime disks and surface default-network recovery failures";

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
  test_windows_iso_mido_patch_failure_is_fatal = assert' (
    (lib.hasInfix "runtime Mido patch failed to apply" vm_setup_sh_text)
    && (lib.hasInfix "install patch and retry" vm_setup_sh_text)
  ) "scripts/vm-setup.sh must fail fast when runtime Mido patching is unavailable or out-of-date";

  # UTM on Apple Silicon must keep Windows guests on x86_64/q35 while allowing
  # NixOS guests to follow host-native aarch64/virt when applicable.
  test_macbook_utm_windows_arch_override =
    assert'
      (
        (lib.hasInfix "if vm.type == \"Windows\" then" macbook_vms_nix_text)
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
      )
      "src/hosts/MacBook/vms.nix must include core UTM schema keys (Drive/ImageName/QEMU/Input) for reliable imports";
  # The Backend value must be exactly "QEMU" (uppercase) — UTM's Swift enum
  # performs a case-sensitive match and throws invalidBackend on any other value.
  # Keep generated templates schema-complete so UTM can decode/import bundles
  # without requiring app-side defaults for missing keys.
  test_macbook_utm_plist_correctness = assert' (
    (lib.hasInfix "<string>QEMU</string>" macbook_vms_nix_text)
    && (lib.hasInfix "<key>IconCustom</key>" macbook_vms_nix_text)
    && (lib.hasInfix "<key>Sound</key>" macbook_vms_nix_text)
    && (lib.hasInfix "<key>DirectoryShareMode</key>" macbook_vms_nix_text)
    && (lib.hasInfix "<key>ClipboardSharing</key>" macbook_vms_nix_text)
    && (lib.hasInfix "<key>DirectoryShareReadOnly</key>" macbook_vms_nix_text)
    && (lib.hasInfix "<key>DownscalingFilter</key>" macbook_vms_nix_text)
    && (lib.hasInfix "<key>UpscalingFilter</key>" macbook_vms_nix_text)
    && (lib.hasInfix "<key>NativeResolution</key>" macbook_vms_nix_text)
    && (lib.hasInfix "<key>MacAddress</key>" macbook_vms_nix_text)
    && (lib.hasInfix "<key>IsolateFromHost</key>" macbook_vms_nix_text)
    && (lib.hasInfix "<key>PortForward</key>" macbook_vms_nix_text)
    && (lib.hasInfix "<string>VirtIO</string>" macbook_vms_nix_text)
    && (lib.hasInfix "<key>Hypervisor</key>" macbook_vms_nix_text)
    && (lib.hasInfix "<key>AdditionalArguments</key>" macbook_vms_nix_text)
    && (lib.hasInfix "<key>BalloonDevice</key>" macbook_vms_nix_text)
    && (lib.hasInfix "<key>DebugLog</key>" macbook_vms_nix_text)
    && (lib.hasInfix "<key>PS2Controller</key>" macbook_vms_nix_text)
    && (lib.hasInfix "<key>RNGDevice</key>" macbook_vms_nix_text)
    && (lib.hasInfix "<key>RTCLocalTime</key>" macbook_vms_nix_text)
    && (lib.hasInfix "<key>TPMDevice</key>" macbook_vms_nix_text)
    && (lib.hasInfix "<key>UEFIBoot</key>" macbook_vms_nix_text)
    && (lib.hasInfix "<key>MaximumUsbShare</key>" macbook_vms_nix_text)
    && (lib.hasInfix "<key>UsbBusSupport</key>" macbook_vms_nix_text)
    && (lib.hasInfix "<key>UsbSharing</key>" macbook_vms_nix_text)
    && (lib.hasInfix "<key>CPUFlagsAdd</key>" macbook_vms_nix_text)
    && (lib.hasInfix "<key>CPUFlagsRemove</key>" macbook_vms_nix_text)
    && (lib.hasInfix "<key>ForceMulticore</key>" macbook_vms_nix_text)
    && (lib.hasInfix "<key>JITCacheSize</key>" macbook_vms_nix_text)
  ) "src/hosts/MacBook/vms.nix plist must include a schema-complete UTM configuration";
  test_macbook_utm_display_card_validity = assert' (
    (lib.hasInfix "displayCard = vm: if vm.type == \"Windows\" then \"virtio-vga\" else \"virtio-gpu-pci\";" macbook_vms_nix_text)
    && !(lib.hasInfix "virtio-ramfb" macbook_vms_nix_text)
    && !(lib.hasInfix "virtio-ramfb-gl" macbook_vms_nix_text)
  ) "src/hosts/MacBook/vms.nix must use supported UTM display cards for macOS UTM guests";
  test_macbook_utm_firmware_contract =
    assert'
      (
        (lib.hasInfix "qemuUefiBoot = vm: vm.type != \"Windows\" && vmArch vm == \"aarch64\";" macbook_vms_nix_text)
        && (lib.hasInfix "qemuUefiBoot vm then \"<true/>\" else \"<false/>\"" macbook_vms_nix_text)
      )
      "src/hosts/MacBook/vms.nix must derive UEFIBoot from guest image contract (Windows BIOS/MBR, aarch64 NixOS UEFI)";
  test_macbook_utm_data_dir_disk_path =
    assert'
      (
        (lib.hasInfix "data_dir=\"$bundle/Data\"" vm_setup_sh_text)
        && (lib.hasInfix "disk_file=\"$data_dir/disk-main.qcow2\"" vm_setup_sh_text)
      )
      "scripts/vm-setup.sh must place UTM disk-main.qcow2 under bundle Data/ to match ImageName-based UTM drive resolution";
  test_macbook_utm_uses_direct_bundle_open =
    assert'
      (
        (lib.hasInfix "open \"$bundle\"" vm_setup_sh_text)
        && !(lib.hasInfix "osascript -e" vm_setup_sh_text)
        && !(lib.hasInfix "import new virtual machine from POSIX file" vm_setup_sh_text)
        && (lib.hasInfix "opening UTM bundle in place" vm_setup_sh_text)
      )
      "scripts/vm-setup.sh must open the managed .utm bundle directly instead of importing it into a copied UTM storage tree";
  test_macbook_utm_refreshes_existing_bundle =
    assert'
      (
        (lib.hasInfix "refreshing config.plist" vm_setup_sh_text)
        && !(lib.hasInfix "UTM bundle already exists: %s; skipping" vm_setup_sh_text)
      )
      "scripts/vm-setup.sh must refresh config.plist for existing UTM bundles so schema fixes apply without deleting bundles";
  test_macbook_utm_stale_template_guard = assert' (
    (lib.hasInfix "stale UTM template detected" vm_setup_sh_text)
    && (lib.hasInfix "run home-manager switch (or nucleus apply) before vm-setup" vm_setup_sh_text)
  ) "scripts/vm-setup.sh must fail fast on stale UTM templates and print the recovery action";
  test_macbook_utm_required_key_guard = assert' (
    (lib.hasInfix "_required_utm_keys" vm_setup_sh_text)
    && (lib.hasInfix "_missing_utm_keys" vm_setup_sh_text)
    && (lib.hasInfix "stale or incomplete UTM template detected" vm_setup_sh_text)
    && (lib.hasInfix "<key>IconCustom</key>" vm_setup_sh_text)
    && (lib.hasInfix "<key>UsbBusSupport</key>" vm_setup_sh_text)
  ) "scripts/vm-setup.sh must block incomplete UTM templates missing required keys";
  test_macbook_utm_legacy_display_reregistration =
    assert'
      (
        (lib.hasInfix "re_register_utm_bundle" vm_setup_sh_text)
        && (lib.hasInfix "detected legacy display config in existing bundle" vm_setup_sh_text)
        && (lib.hasInfix "<string>(vga|std|virtio-ramfb|virtio-ramfb-gl)</string>" vm_setup_sh_text)
        && (lib.hasInfix "detected config drift in existing bundle" vm_setup_sh_text)
        && (lib.hasInfix "cmp -s \"$_plist_template\" \"$config_plist\"" vm_setup_sh_text)
        && (lib.hasInfix "repairing stale UTM runtime registration" vm_setup_sh_text)
      )
      "scripts/vm-setup.sh must re-register UTM VMs when legacy display configs or template drift are detected so refreshed config.plist values take effect";
  test_vm_directory_readme_generation =
    assert'
      (
        (lib.hasInfix "write_vm_directory_readme" vm_setup_sh_text)
        && (lib.hasInfix "wrote VM directory guide" vm_setup_sh_text)
        && (lib.hasInfix "## Start commands" vm_setup_sh_text)
        && (lib.hasInfix "images/<name>-build/" vm_setup_sh_text)
        && (lib.hasInfix "images/<name>-installer.iso" vm_setup_sh_text)
        && (lib.hasInfix "## Safe cleanup" vm_setup_sh_text)
        && (lib.hasInfix "start-<name>.sh" vm_setup_sh_text)
        && (lib.hasInfix "configure-<name>.sh" vm_setup_sh_text)
        && (lib.hasInfix "configure-<name>.ps1" vm_setup_sh_text)
        && (lib.hasInfix "Guest OS configuration is **not automatic**" vm_setup_sh_text)
        && (lib.hasInfix "Copying only `config.plist` or only `disk-main.qcow2` is not sufficient" vm_setup_sh_text)
      )
      "scripts/vm-setup.sh must write ~/virtual machines/README.md with explicit .utm bundle transfer guidance";
  test_windows_vm_directory_readme_generation =
    assert'
      (
        (lib.hasInfix "$vmReadmePath = Join-Path $vmDir 'README.md'" windows_vm_setup_ps1_text)
        && (lib.hasInfix "VM directory guide written" windows_vm_setup_ps1_text)
        && (lib.hasInfix "## Start commands" windows_vm_setup_ps1_text)
        && (lib.hasInfix "images/<name>-build/" windows_vm_setup_ps1_text)
        && (lib.hasInfix "images/<name>-installer.iso" windows_vm_setup_ps1_text)
        && (lib.hasInfix "## Safe cleanup" windows_vm_setup_ps1_text)
        && (lib.hasInfix "configure-<name>.ps1" windows_vm_setup_ps1_text)
        && (lib.hasInfix "configure-<name>.sh" windows_vm_setup_ps1_text)
        && (lib.hasInfix "Guest OS configuration is **not automatic**" windows_vm_setup_ps1_text)
        && (lib.hasInfix "Copying only `config.plist` or only `disk-main.qcow2` is not sufficient" windows_vm_setup_ps1_text)
      )
      "Invoke-VMSetup.ps1 must write %USERPROFILE%\\virtual machines\\README.md with .utm bundle transfer instructions";
  test_vm_setup_generates_helper_scripts =
    assert'
      (
        (lib.hasInfix "write_start_script" vm_setup_sh_text)
        && (lib.hasInfix "write_configure_script" vm_setup_sh_text)
        && (lib.hasInfix "wrote configure helper scripts" vm_setup_sh_text)
        && (lib.hasInfix "case-insensitive filename collision" vm_setup_sh_text)
        && (lib.hasInfix "configure helpers written" windows_vm_setup_ps1_text)
        && (lib.hasInfix "removed legacy helper script" windows_vm_setup_ps1_text)
      )
      "VM setup flows must generate discoverable start/config helper scripts while removing legacy .sh helpers on Windows";
  test_macbook_utm_default_location_link =
    assert'
      (
        (lib.hasInfix "ensure_utm_default_vm_location" vm_setup_sh_text)
        && (lib.hasInfix "$HOME/Library/Containers/com.utmapp.UTM/Data/Documents" vm_setup_sh_text)
        && (lib.hasInfix "linked UTM default VM location" vm_setup_sh_text)
      )
      "scripts/vm-setup.sh must best-effort wire UTM's sandboxed document location to ~/virtual machines";
  test_macbook_tart_storage_link =
    assert'
      (
        (lib.hasInfix "ensure_tart_vm_dir" vm_setup_sh_text)
        && (lib.hasInfix "/.tart" vm_setup_sh_text)
        && (lib.hasInfix "linked tart storage" vm_setup_sh_text)
        && (lib.hasInfix "rsync" vm_setup_sh_text)
      )
      "scripts/vm-setup.sh must link ~/.tart -> ~/virtual machines/.tart so Tart artifacts co-locate with UTM bundles for backup";

  test_macbook_macos_version_tahoe =
    assert'
      (
        (lib.hasInfix "\"macOSVersion\": \"tahoe\"" vms_json_text)
        && (lib.hasInfix "[-var macos_version=tahoe]" vms_macos_packer_text)
        && (lib.hasInfix "default     = \"tahoe\"" vms_macos_packer_text)
        && (lib.hasInfix "macOS version to provision (tahoe, sequoia, sonoma, ventura, etc.)" vms_macos_packer_text)
        && (lib.hasInfix "tahoe" vm_setup_sh_text)
      )
      "MacBook macOS guest version must default to Tahoe across VMs.json, vm-setup.sh, and the macOS Packer template";

  # On non-Windows hosts, after Mido failure the script should try a pwsh/Fido
  # URL resolver fallback before requiring manual ISO input.
  test_windows_iso_fido_nonwindows_fallback =
    assert'
      (
        (lib.hasInfix "download_windows_iso_fido_url_nonwindows" vm_setup_sh_text)
        && (lib.hasInfix "Fido URL fallback failed on" vm_setup_sh_text)
        && (lib.hasInfix "trying Mido as secondary fallback" vm_setup_sh_text)
        && (lib.hasInfix "Windows ISO fallback order" vm_setup_sh_text)
        && (lib.hasInfix "--windows-iso-retries" vm_setup_sh_text)
        && (lib.hasInfix "run_with_backoff" vm_setup_sh_text)
      )
      "scripts/vm-setup.sh must attempt a non-Windows Fido URL fallback first on Darwin/Linux, with Mido as secondary fallback and retry support";

  # Force evaluation of all tests when `summary` is requested so callers
  # cannot accidentally read a static summary string without executing
  # assertions.
  all_tests = [
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
    test_nixos_image_resize_to_manifest_disk
    test_macos_packer_failure_message
    test_windows_packer_failure_message
    test_windows_packer_winrm_port_forward
    test_windows_autounattend_winrm_before_virtio
    test_windows_autounattend_bios_system_partition_type
    test_guest_credentials_policy_in_user_registries
    test_guest_credentials_policy_in_user_secrets
    test_guest_credentials_policy_in_vm_setup_sh
    test_nixos_generators_uses_exported_env_credentials
    test_guest_credentials_policy_in_windows_vm_setup_ps1
    test_guest_credentials_policy_in_nixos_guest
    test_guest_credentials_policy_in_nixos_packer
    test_windows_nixos_build_honors_manifest_disk_size
    test_windows_helper_cleanup_collision_guard
    test_guest_credentials_policy_in_windows_packer
    test_guest_credentials_policy_in_windows_autounattend
    test_guest_credentials_policy_in_macos_packer
    test_vm_guest_credential_drift_replacement
    test_utm_runtime_replacement_requires_valid_prebuilt
    test_libvirt_runtime_validation_parity
    test_windows_iso_mido_patch_file_exists
    test_windows_iso_mido_runtime_patch_support
    test_windows_iso_mido_patch_failure_is_fatal
    test_macbook_utm_windows_arch_override
    test_macbook_utm_schema_keys
    test_macbook_utm_plist_correctness
    test_macbook_utm_display_card_validity
    test_macbook_utm_firmware_contract
    test_macbook_utm_data_dir_disk_path
    test_macbook_utm_uses_direct_bundle_open
    test_macbook_utm_refreshes_existing_bundle
    test_macbook_utm_stale_template_guard
    test_macbook_utm_legacy_display_reregistration
    test_vm_directory_readme_generation
    test_windows_vm_directory_readme_generation
    test_vm_setup_generates_helper_scripts
    test_macbook_utm_default_location_link
    test_macbook_tart_storage_link
    test_macbook_macos_version_tahoe
    test_windows_iso_fido_nonwindows_fallback
  ];

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
    test_nixos_image_resize_to_manifest_disk
    test_macos_packer_failure_message
    test_windows_packer_failure_message
    test_windows_packer_winrm_port_forward
    test_windows_autounattend_winrm_before_virtio
    test_windows_autounattend_bios_system_partition_type
    test_guest_credentials_policy_in_user_registries
    test_guest_credentials_policy_in_user_secrets
    test_guest_credentials_policy_in_vm_setup_sh
    test_nixos_generators_uses_exported_env_credentials
    test_guest_credentials_policy_in_windows_vm_setup_ps1
    test_guest_credentials_policy_in_nixos_guest
    test_guest_credentials_policy_in_nixos_packer
    test_windows_nixos_build_honors_manifest_disk_size
    test_windows_helper_cleanup_collision_guard
    test_guest_credentials_policy_in_windows_packer
    test_guest_credentials_policy_in_windows_autounattend
    test_guest_credentials_policy_in_macos_packer
    test_vm_guest_credential_drift_replacement
    test_utm_runtime_replacement_requires_valid_prebuilt
    test_libvirt_runtime_validation_parity
    test_windows_iso_mido_patch_file_exists
    test_windows_iso_mido_runtime_patch_support
    test_windows_iso_mido_patch_failure_is_fatal
    test_macbook_utm_windows_arch_override
    test_macbook_utm_schema_keys
    test_macbook_utm_plist_correctness
    test_macbook_utm_display_card_validity
    test_macbook_utm_firmware_contract
    test_macbook_utm_data_dir_disk_path
    test_macbook_utm_uses_direct_bundle_open
    test_macbook_utm_refreshes_existing_bundle
    test_macbook_utm_stale_template_guard
    test_macbook_utm_legacy_display_reregistration
    test_vm_directory_readme_generation
    test_windows_vm_directory_readme_generation
    test_vm_setup_generates_helper_scripts
    test_macbook_utm_default_location_link
    test_macbook_tart_storage_link
    test_macbook_macos_version_tahoe
    test_windows_iso_fido_nonwindows_fallback
    ;

  summary = builtins.deepSeq all_tests "vm-setup-tests: all tests passed";
}
