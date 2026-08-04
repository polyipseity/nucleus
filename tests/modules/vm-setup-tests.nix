# tests/modules/vm-setup-tests.nix — VM provisioning manifest and NixOS module options.

let
  lib = import <nixpkgs/lib>;
  inherit (import ../lib.nix) assert';

  manifest = builtins.fromJSON (builtins.readFile ../../src/modules/VMs.json);

  # Required fields for every VM entry.
  requiredFields = [
    "name"
    "display"
    "enabled"
    "cpus"
    "ramBytes"
    "diskBytes"
    "type"
    "shareDevDir"
    "windowsIsoUrl"
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
    assert' (
      builtins.length manifest.VMs > 0 && builtins.all (r: r == null) results
    ) "VMs.json must declare at least one VM";

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
    "Android"
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

  # enabled must be a boolean.
  test_enabled_types =
    let
      badEnabled = builtins.filter (vm: !builtins.isBool vm.enabled) manifest.VMs;
    in
    assert' (badEnabled == [ ])
      "enabled must be a boolean for all VMs; bad entries: ${
        builtins.toString (builtins.map (v: v.name) badEnabled)
      }";

  # windowsIsoUrl must be present on every VM, and must be a string or null.
  test_windows_iso_url_type =
    let
      missingIsoUrls = builtins.filter (vm: !builtins.hasAttr "windowsIsoUrl" vm) manifest.VMs;
      badIsoUrls = builtins.filter (
        vm:
        builtins.hasAttr "windowsIsoUrl" vm
        && !(builtins.isString vm.windowsIsoUrl || builtins.isNull vm.windowsIsoUrl)
      ) manifest.VMs;
    in
    assert' (missingIsoUrls == [ ] && badIsoUrls == [ ])
      "windowsIsoUrl is required on all VMs (must be string or null); missing: ${
        builtins.toString (builtins.map (v: v.name) missingIsoUrls)
      }; bad types: ${builtins.toString (builtins.map (v: v.name) badIsoUrls)}";

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

  # androidGsiUrl must be a string or null when present; the field is optional (Android guests only).
  test_android_gsi_url_type =
    let
      badGsiUrls = builtins.filter (
        vm:
        builtins.hasAttr "androidGsiUrl" vm
        && !(builtins.isString vm.androidGsiUrl || builtins.isNull vm.androidGsiUrl)
      ) manifest.VMs;
    in
    assert' (badGsiUrls == [ ])
      "androidGsiUrl must be a string or null for all VMs that declare it; bad entries: ${
        builtins.toString (builtins.map (v: v.name) badGsiUrls)
      }";

  # androidGsiUrl must only appear on VMs with type Android.
  test_android_gsi_url_only_on_android =
    let
      badGsiUrlVms = builtins.filter (
        vm: builtins.hasAttr "androidGsiUrl" vm && vm.type != "Android"
      ) manifest.VMs;
    in
    assert' (badGsiUrlVms == [ ])
      "androidGsiUrl must only appear on VMs of type Android; bad entries: ${
        builtins.toString (builtins.map (v: v.name) badGsiUrlVms)
      }";

  # Android must disable guest audio (sound == "none"): UTM's SPICE audio
  # pipeline teardown deadlocks against the CoreAudio IO thread, freezing the
  # display (see .agents/instructions/utm-android-freeze.instructions.md).
  test_android_sound_disabled =
    let
      androidVms = builtins.filter (vm: vm.type == "Android") manifest.VMs;
    in
    assert' (
      builtins.length androidVms == 1 && (builtins.head androidVms).sound == "none"
    ) "VMs.json Android entry must declare sound == \"none\" (UTM SPICE audio deadlock workaround)";

  # hosts must be absent, null, or a non-empty array of valid host names
  # (["MacBook", "NixOS", "Windows"]). This enables host-scoped VM availability
  # so different machines see only their intended VMs.
  validHosts = [
    "MacBook"
    "NixOS"
    "Windows"
  ];
  test_hosts_field =
    let
      badHosts = builtins.filter (
        vm:
        let
          h = vm.hosts or null;
        in
        h != null
        && (
          !builtins.isList h
          || builtins.length h == 0
          || !builtins.all (host: builtins.elem host validHosts) h
        )
      ) manifest.VMs;
    in
    assert' (badHosts == [ ])
      "hosts must be null, absent, or a non-empty list of valid host names (MacBook, NixOS, Windows); bad entries: ${
        builtins.toString (builtins.map (v: "${v.name}: ${builtins.toString (v.hosts or null)}") badHosts)
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
  # Ensures that nucleus-vm has all its required input files.
  test_packer_templates_exist =
    let
      checks = [
        {
          cond = builtins.pathExists ../../src/vms/nixos/guest.nix;
          msg = "src/vms/nixos/guest.nix must exist for nixos-generators builds";
        }
        {
          cond = builtins.pathExists ../../src/vms/nixos/packer.pkr.hcl;
          msg = "src/vms/nixos/packer.pkr.hcl must exist for Windows-host NixOS builds";
        }
        {
          cond = builtins.pathExists ../../src/vms/windows/packer.pkr.hcl;
          msg = "src/vms/windows/packer.pkr.hcl must exist for Windows 11 builds";
        }
        {
          cond = builtins.pathExists ../../src/vms/windows/Autounattend.xml;
          msg = "src/vms/windows/Autounattend.xml must exist for Windows 11 Packer builds";
        }
        {
          cond = builtins.pathExists ../../src/vms/macos/packer.pkr.hcl;
          msg = "src/vms/macos/packer.pkr.hcl must exist for macOS Tart builds";
        }
      ];
      results = builtins.map (c: assert' c.cond c.msg) checks;
    in
    assert' (builtins.all (r: r == null) results) "Packer template file existence check failed";

  # VM setup templates (standalone files extracted from inline HERE-docs/strings)
  # must exist for orchestrator rendering.
  test_vm_templates_exist =
    let
      checks = [
        {
          cond = builtins.pathExists ../../src/vms/templates/README.md;
          msg = "src/vms/templates/README.md must exist for cross-host VM directory guide";
        }
        {
          cond = builtins.pathExists ../../src/vms/templates/start-posix.sh;
          msg = "src/vms/templates/start-posix.sh must exist for POSIX VM start scripts";
        }
        {
          cond = builtins.pathExists ../../src/vms/templates/start-windows.ps1;
          msg = "src/vms/templates/start-windows.ps1 must exist for Windows VM start scripts";
        }
        {
          cond = builtins.pathExists ../../src/vms/templates/start-windows-host.sh;
          msg = "src/vms/templates/start-windows-host.sh must exist for Git Bash/MSYS VM start scripts";
        }
        {
          cond = builtins.pathExists ../../src/vms/templates/start-host.ps1;
          msg = "src/vms/templates/start-host.ps1 must exist for POSIX-host PowerShell VM start scripts";
        }
        {
          cond = builtins.pathExists ../../src/vms/templates/stop-posix.sh;
          msg = "src/vms/templates/stop-posix.sh must exist for POSIX VM stop scripts";
        }
        {
          cond = builtins.pathExists ../../src/vms/templates/stop-host.ps1;
          msg = "src/vms/templates/stop-host.ps1 must exist for PowerShell VM stop scripts (incl. Windows QEMU)";
        }
      ];
      results = builtins.map (c: assert' c.cond c.msg) checks;
    in
    assert' (builtins.all (r: r == null) results) "VM template file existence check failed";

  # vm-setup scripts must exist for both POSIX and Windows hosts.
  test_vm_setup_scripts_exist =
    let
      checks = [
        {
          cond = builtins.pathExists ../../scripts/vm.sh;
          msg = "scripts/vm.sh must exist";
        }
        {
          cond = builtins.pathExists ../../scripts/vm.ps1;
          msg = "scripts/vm.ps1 must exist";
        }
      ];
      results = builtins.map (c: assert' c.cond c.msg) checks;
    in
    assert' (builtins.all (r: r == null) results) "VM setup script existence check failed";

  # Every enabled VM must be reachable by at least one known host (MacBook,
  # NixOS, Windows).  An orphaned VM (enabled but with a hosts list that
  # excludes all known hosts) would never be provisioned by any machine.
  # This mirrors the get_expected_vm_names filter logic used by vm-setup GC.
  test_enabled_vm_not_orphaned =
    let
      hostFilter = vm: builtins.any (host: builtins.elem host (vm.hosts or null)) validHosts;
      orphaned = builtins.filter (
        vm: vm.enabled && !(builtins.isNull (vm.hosts or null)) && !hostFilter vm
      ) manifest.VMs;
    in
    assert' (orphaned == [ ])
      "Every enabled VM must be reachable by at least one known host; orphaned: ${
        builtins.toString (builtins.map (v: v.name) orphaned)
      }";

  # GC must preserve disabled VM entries by default: only names absent from
  # VMs.json entirely are cleared.  --gc-disabled opts into clearing disabled
  # entries, narrowing the expected set to enabled-and-host-matched VMs.
  test_vm_gc_preserves_disabled_entries_by_default = assert' (
    (lib.hasInfix "vm_get_manifest_vm_names" vm_setup_sh_text)
    && (lib.hasInfix "if [ \"\$gc_disabled_mode\" = true ]" vm_setup_sh_text)
    && (lib.hasInfix "gc_disabled_mode=false" vm_setup_sh_text)
    && (lib.hasInfix "_gcv_expected=\"\$(vm_get_manifest_vm_names)\"" vm_setup_sh_text)
  ) "vm-setup GC must preserve disabled VM entries by default and clear them only with --gc-disabled";

  # The --gc-disabled/--no-gc-disabled option pair must be accepted in both
  # parse loops (global and post-subcommand) and documented in usage.
  test_vm_gc_disabled_option_pair = assert' (
    (lib.hasInfix "--gc-disabled) gc_disabled_mode=true; shift ;;" vm_setup_sh_text)
    && (lib.hasInfix "--no-gc-disabled) gc_disabled_mode=false; shift ;;" vm_setup_sh_text)
    && (lib.hasInfix "--gc-disabled) gc_disabled_mode=true ;;" vm_setup_sh_text)
    && (lib.hasInfix "--no-gc-disabled) gc_disabled_mode=false ;;" vm_setup_sh_text)
    && (lib.hasInfix "--gc-disabled|--no-gc-disabled" vm_setup_sh_text)
  ) "vm.sh must accept the --gc-disabled/--no-gc-disabled option pair in both parse loops and usage";

  # Windows vm-setup must mirror POSIX GC: preserve disabled entries by
  # default, clear them only with -GcDisabled (--gc-disabled/--no-gc-disabled).
  test_windows_vm_gc_preserves_disabled_entries_by_default =
    assert'
      (
        (lib.hasInfix "[switch]\$GcDisabled" windows_vm_setup_ps1_text)
        && (lib.hasInfix "\$expectedNames = @(\$vmDef.VMs | ForEach-Object { \$_.name })" windows_vm_setup_ps1_text)
        && (lib.hasInfix "'--gc-disabled' { \$invokeArgs['GcDisabled'] = \$true }" vm_ps1_text)
        && (lib.hasInfix "'--no-gc-disabled' { \$invokeArgs['GcDisabled'] = \$false }" vm_ps1_text)
      )
      "Windows vm-setup GC must preserve disabled VM entries by default and clear them only with --gc-disabled/-GcDisabled";

  # guest.nix must be non-empty (parseable as a Nix expression).
  test_guest_nix_nonempty =
    let
      content = builtins.readFile ../../src/vms/nixos/guest.nix;
    in
    assert' (builtins.stringLength content > 0) "src/vms/nixos/guest.nix must not be empty";

  # The NixOS guest image must not force virtio_fs into the initrd. The share
  # is optional at runtime and some current kernels do not provide a loadable
  # virtio_fs module, which would make image generation fail before first boot.
  guest_nix_text = builtins.readFile ../../src/vms/nixos/guest.nix;
  core_nix_text = builtins.readFile ../../src/modules/core.nix;
  nixos_packer_text = builtins.readFile ../../src/vms/nixos/packer.pkr.hcl;
  test_nixos_guest_virtiofs_not_forced = assert' (
    !(lib.hasInfix "boot.initrd.availableKernelModules = [ \"virtio_fs\" ];" guest_nix_text)
    && !(lib.hasInfix "boot.initrd.availableKernelModules = [ \\\"virtio_fs\\\" ];" nixos_packer_text)
  ) "NixOS guest generation must not force virtio_fs into the initrd on current kernels";

  # NixOS guest must enable the QEMU guest agent for host-guest communication
  # (VM lifecycle events, ballooning, clipboard sharing, etc.)
  test_nixos_guest_qemu_guest_enabled = assert' (lib.hasInfix "services.qemuGuest.enable = true;" guest_nix_text) "NixOS guest.nix must enable services.qemuGuest.enable";

  # NixOS guest must enable OpenSSH for remote access and credential-free
  # host-guest communication via the QEMU SSH port forward.
  test_nixos_guest_openssh_enabled = assert' (lib.hasInfix "services.openssh.enable = true;" guest_nix_text) "NixOS guest.nix must enable services.openssh.enable";

  # NixOS guest must declare the nucleus-rebuild oneshot systemd service for
  # converging the guest to the latest flake-defined state.
  test_nixos_guest_nucleus_rebuild_service = assert' (lib.hasInfix "systemd.services.nucleus-rebuild" guest_nix_text) "NixOS guest.nix must declare the nucleus-rebuild systemd service";

  # NixOS guest must accept the SSH public key via the
  # NUCLEUS_VM_GUEST_SSH_PUBLIC_KEY environment variable so the host can
  # authenticate to the guest without interactive password entry.
  test_nixos_guest_ssh_authorized_keys = assert' (lib.hasInfix "NUCLEUS_VM_GUEST_SSH_PUBLIC_KEY" guest_nix_text) "NixOS guest.nix must reference NUCLEUS_VM_GUEST_SSH_PUBLIC_KEY in authorized keys";

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
  linuxBuilderSshConfigText = builtins.readFile ../../src/modules/configs/ssh/ssh_config.d/100-linux-builder.conf;
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
        (lib.hasInfix "IdentitiesOnly yes" linuxBuilderSshConfigText)
        && (lib.hasInfix "Match originalhost linux-builder localuser root" linuxBuilderSshConfigText)
        && (lib.hasInfix "Match originalhost linux-builder localuser __USERNAME__" linuxBuilderSshConfigText)
      )
      "MacBook linux-builder.nix must route root and the primary user to separate builder identity files without falling back to unrelated SSH agent keys";

  # The MacBook base.nix must point the Nix daemon at /etc/nix/machines so the
  # linux-builder registration written by nix-darwin is actually used.
  nixCustomConfText = builtins.readFile ../../src/modules/configs/nix/nix.custom.conf;
  test_macbook_builders_machines = assert' (lib.hasInfix "builders = @/etc/nix/machines" nixCustomConfText) "MacBook base.nix must set builders = @/etc/nix/machines in nix.extraOptions";

  # vm.sh must capture the Packer exit code for the macOS Tart build so
  # a failed packer invocation does not falsely report success.
  # Combined text: vm.sh is sourced by vm.sh, so patterns from both files
  # belong to the same script.  Checking only vm.sh misses patterns
  # that were extracted to vm.sh during refactoring.
  vm_setup_sh_text =
    builtins.readFile ../../scripts/vm.sh + builtins.readFile ../../src/scripts/lib/vm.sh;
  vm_ps1_text = builtins.readFile ../../scripts/vm.ps1;
  windows_vm_setup_ps1_text = builtins.readFile ../../src/hosts/Windows/modules/system/Invoke-VMSetup.ps1;
  readmeTemplateText = builtins.readFile ../../src/vms/templates/README.md;
  startPosixTemplateText = builtins.readFile ../../src/vms/templates/start-posix.sh;
  startWindowsTemplateText = builtins.readFile ../../src/vms/templates/start-windows.ps1;
  startWindowsHostTemplateText = builtins.readFile ../../src/vms/templates/start-windows-host.sh;
  startHostPs1TemplateText = builtins.readFile ../../src/vms/templates/start-host.ps1;
  stopPosixShTemplateText = builtins.readFile ../../src/vms/templates/stop-posix.sh;
  stopHostPs1TemplateText = builtins.readFile ../../src/vms/templates/stop-host.ps1;
  macbook_vms_nix_text = builtins.readFile ../../src/hosts/MacBook/vms.nix;
  nixos_vms_nix_text = builtins.readFile ../../src/hosts/NixOS/vms.nix;
  utmConfigPlistText = builtins.readFile ../../src/modules/configs/vms/utm-config.plist.xml;
  vms_json_text = builtins.readFile ../../src/modules/VMs.json;
  users_json_text = builtins.readFile ../../src/modules/users.json;
  windows_users_json_text = builtins.readFile ../../src/hosts/Windows/users.json;
  user_secret_text = builtins.readFile ../../src/secrets/users-polyipseity.yml;
  vms_windows_packer_text = builtins.readFile ../../src/vms/windows/packer.pkr.hcl;
  vms_windows_autounattend_text = builtins.readFile ../../src/vms/windows/Autounattend.xml;
  vms_macos_packer_text = builtins.readFile ../../src/vms/macos/packer.pkr.hcl;
  test_macos_packer_exit_check = assert' (lib.hasInfix "_packer_status=0" vm_setup_sh_text) "scripts/vm.sh must capture packer exit status (_packer_status=0)";

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
      "scripts/vm.sh must give nixos-generators a non-existent output link path and resolve the resulting symlink";

  # nixos-generators produces a small default qcow2 unless resized explicitly.
  # vm-setup must resize NixOS images to manifest disk size so provisioning
  # logic does not reject the pre-built image for being too small.
  test_nixos_image_resize_to_manifest_disk = assert' (
    (lib.hasInfix "vm_build_nixos NAME DISK_GIB" vm_setup_sh_text)
    && (lib.hasInfix "if ! resize_and_mark_image \"$_out\" \"$_marker\" \"$_disk_gib\"; then" vm_setup_sh_text)
  ) "scripts/vm.sh must resize generated NixOS qcow2 images to the manifest disk size";

  # The Packer failure branch for the macOS build must print a human-readable
  # error and return the captured exit code.
  test_macos_packer_failure_message = assert' (lib.hasInfix "Packer build for macOS VM" vm_setup_sh_text) "scripts/vm.sh must print a failure message for a failed macOS Packer build";

  # The Packer failure branch for the Windows build must also surface the error.
  test_windows_packer_failure_message = assert' (lib.hasInfix "Packer build for Windows VM" vm_setup_sh_text) "scripts/vm.sh must print a failure message for a failed Windows Packer build";

  # Windows QEMU builds must:
  # 1. Use SSH communicator with explicit port forward (not random NAT mapping)
  # 2. Keep boot_wait=5s and pause_before_connecting=120s
  # 3. Expose selectable firmware_mode and boot_strategy in packer.pkr.hcl
  # 4. Retry packer builds in vm-setup wrappers with EFI-first + BIOS fallback
  #    before giving up, so installer timing changes do not hard-lock on one
  #    brittle keying pattern.
  test_windows_packer_ssh_port_forward =
    assert'
      (
        (lib.hasInfix "communicator = \"ssh\"" vms_windows_packer_text)
        && (lib.hasInfix "skip_nat_mapping = true" vms_windows_packer_text)
        && (lib.hasInfix "hostfwd=tcp::2222-:22" vms_windows_packer_text)
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
      "Windows VM packer template must use SSH communicator with port 2222 forwarding and expose controlled firmware/debug knobs";

  # Autounattend.xml must configure OpenSSH before VirtIO driver scan to prevent blocking.
  test_windows_autounattend_ssh_before_virtio =
    assert'
      (
        (lib.hasInfix "<Order>1</Order>" vms_windows_autounattend_text)
        && (lib.hasInfix "Add-WindowsCapability -Online -Name OpenSSH.Server" vms_windows_autounattend_text)
        && (lib.hasInfix "<Order>3</Order>" vms_windows_autounattend_text)
        && (lib.hasInfix "VirtIO" vms_windows_autounattend_text)
      )
      "src/vms/windows/Autounattend.xml must configure OpenSSH in Orders 1–3 before VirtIO driver scan so SSH is ready even if driver scan is slow";
  # BIOS installs need a normal NTFS partition type for the active system
  # partition. TypeID 0x27 is a recovery/hidden partition type and can leave
  # SeaBIOS stuck at "Booting from Hard Disk...".
  test_windows_autounattend_bios_system_partition_type =
    assert'
      (
        (lib.hasInfix "<TypeID>0x07</TypeID>" vms_windows_autounattend_text)
        && !(lib.hasInfix "<TypeID>0x27</TypeID>" vms_windows_autounattend_text)
      )
      "src/vms/windows/Autounattend.xml must keep the active BIOS system partition TypeID at 0x07 (not 0x27)";

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
      "scripts/vm.sh must resolve guest credentials from per-user SOPS secrets and export/pass them to guest builders";

  test_nixos_generators_uses_exported_env_credentials =
    assert'
      (
        (lib.hasInfix "guestUsername = builtins.getEnv \"NUCLEUS_VM_GUEST_USERNAME\"" guest_nix_text)
        && (lib.hasInfix "guestPassword = builtins.getEnv \"NUCLEUS_VM_GUEST_PASSWORD\"" guest_nix_text)
        && !(lib.hasInfix "--argstr guestUsername" vm_setup_sh_text)
        && !(lib.hasInfix "--argstr guestPassword" vm_setup_sh_text)
      )
      "scripts/vm.sh must let nixos-generators consume exported guest credentials directly instead of passing unsupported --argstr flags";

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
  ) "src/vms/nixos/guest.nix must consume exported guest credentials and create a login user";

  test_guest_credentials_policy_in_nixos_packer =
    assert'
      (
        (lib.hasInfix "variable \"guest_username\"" nixos_packer_text)
        && (lib.hasInfix "variable \"guest_password\"" nixos_packer_text)
        && (lib.hasInfix "users.users.\\\"\${var.guest_username}\\\"" nixos_packer_text)
        && !(lib.hasInfix "default     = \"nixos\"" nixos_packer_text)
      )
      "src/vms/nixos/packer.pkr.hcl must accept and apply guest credentials for Windows-host NixOS builds";

  test_windows_nixos_build_honors_manifest_disk_size =
    assert'
      (
        (lib.hasInfix "-DiskGib $diskGib" windows_vm_setup_ps1_text)
        && (lib.hasInfix "[int]$DiskGib" windows_vm_setup_ps1_text)
        && (lib.hasInfix "-var \"disk_size=\${DiskGib}G\"" windows_vm_setup_ps1_text)
      )
      "Invoke-VMSetup.ps1 must pass the manifest-derived disk size into Windows-host NixOS Packer builds";

  test_guest_credentials_policy_in_windows_packer =
    assert'
      (
        (lib.hasInfix "variable \"guest_username\"" vms_windows_packer_text)
        && (lib.hasInfix "variable \"guest_password\"" vms_windows_packer_text)
        && (lib.hasInfix "variable \"autounattend_path\"" vms_windows_packer_text)
        && (lib.hasInfix "ssh_username = var.guest_username" vms_windows_packer_text)
        && (lib.hasInfix "ssh_password = var.guest_password" vms_windows_packer_text)
        && (lib.hasInfix "var.autounattend_path" vms_windows_packer_text)
      )
      "src/vms/windows/packer.pkr.hcl must wire guest credentials into SSH communicator and consume a rendered Autounattend path";

  test_guest_credentials_policy_in_windows_autounattend =
    assert'
      (
        (lib.hasInfix "__NUCLEUS_GUEST_USERNAME__" vms_windows_autounattend_text)
        && (lib.hasInfix "__NUCLEUS_GUEST_PASSWORD__" vms_windows_autounattend_text)
      )
      "src/vms/windows/Autounattend.xml must expose guest credential placeholders for runtime rendering";

  test_guest_credentials_policy_in_macos_packer =
    assert'
      (
        (lib.hasInfix "variable \"guest_username\"" vms_macos_packer_text)
        && (lib.hasInfix "variable \"guest_password\"" vms_macos_packer_text)
        && (lib.hasInfix "sysadminctl -addUser" vms_macos_packer_text)
      )
      "src/vms/macos/packer.pkr.hcl must provision a guest account using the secret-backed guest credential policy";

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

  # guest.nix lives at src/vms/nixos/, so repo imports resolve via ../../../src/
  # (three levels up). Two levels (../../src) would hit the nonexistent
  # src/src/ path — the regression that left the NixOS image unbuildable after
  # the file moved from vms/nixos/ to src/vms/nixos/.
  test_nixos_guest_import_paths_resolve =
    assert'
      (
        (lib.hasInfix "../../../src/modules/core.nix" guest_nix_text)
        && (lib.hasInfix "../../../src/hosts/NixOS/desktop.nix" guest_nix_text)
        # WHY: negative checks must be newline-anchored: "../../../src/..." contains
        # "../../src/..." as a substring, so a bare !hasInfix always fails.
        && !(lib.hasInfix "\n    ../../src/modules/core.nix" guest_nix_text)
        && !(lib.hasInfix "\n    ../../src/hosts/NixOS/desktop.nix" guest_nix_text)
      )
      "src/vms/nixos/guest.nix must import repo files via ../../../src/ (three levels up from src/vms/nixos/)";

  # The NixOS image and runtime disks must rebuild when the guest config
  # (guest.nix, its imports, flake.lock) drifts, not just on credential drift;
  # otherwise stale images ship silently after guest.nix changes.
  test_nixos_guest_config_drift_rebuild =
    assert'
      (
        (lib.hasInfix "vm_guest_config_marker_path" vm_setup_sh_text)
        && (lib.hasInfix "vm_guest_config_marker_matches" vm_setup_sh_text)
        && (lib.hasInfix "vm_guest_config_fingerprint" vm_setup_sh_text)
        && (lib.hasInfix ".vm-guest-config-sha256" vm_setup_sh_text)
        && (lib.hasInfix "NixOS image guest config drift detected" vm_setup_sh_text)
        && (lib.hasInfix "runtime disk guest config drift detected" vm_setup_sh_text)
        && (lib.hasInfix "src/flake.lock" vm_setup_sh_text)
      )
      "scripts/vm.sh must rebuild the NixOS image and replace runtime disks when the guest config fingerprint drifts";

  # The NixOS guest must NOT import the host-only SOPS modules: they define
  # sops.* options that only exist when sops-nix.nixosModules.sops is loaded,
  # which the standalone nixos-generators evaluation does not do.  The guest
  # injects credentials via NUCLEUS_VM_GUEST_* env vars instead.
  test_nixos_guest_avoids_host_sops_modules =
    assert'
      (
        !(lib.hasInfix "../../../src/modules/posix-sops.nix" guest_nix_text)
        && !(lib.hasInfix "../../../src/hosts/NixOS/sops.nix" guest_nix_text)
        && (lib.hasInfix "NUCLEUS_VM_GUEST_* environment variables instead of SOPS" guest_nix_text)
      )
      "src/vms/nixos/guest.nix must not import host-only SOPS modules that break the standalone nixos-generators evaluation";

  # The NixOS guest must thread username (and hostName) through _module.args
  # because nixos-generators passes no specialArgs; shared modules key off both.
  test_nixos_guest_threads_username_arg =
    assert'
      (
        (lib.hasInfix "_module.args = {" guest_nix_text)
        && (lib.hasInfix "username = guestUsername;" guest_nix_text)
        && (lib.hasInfix "hostName = \"NixOS\";" guest_nix_text)
      )
      "src/vms/nixos/guest.nix must thread username/hostName via _module.args for standalone nixos-generators evals";

  # The NixOS guest must force overrides on host modules whose defaults cannot
  # evaluate on aarch64-linux or collide under the standalone evaluation.
  test_nixos_guest_standalone_eval_overrides =
    assert'
      (
        (lib.hasInfix "services.gnome.gcr-ssh-agent.enable = lib.mkForce false;" guest_nix_text)
        && (lib.hasInfix "hardware.graphics.enable32Bit = lib.mkForce false;" guest_nix_text)
        && (lib.hasInfix "programs.steam.enable = lib.mkForce false;" guest_nix_text)
        && (lib.hasInfix "system.stateVersion = lib.mkForce \"25.05\";" guest_nix_text)
        && (lib.hasInfix "allowUnfree = true;" guest_nix_text)
        && (lib.hasInfix "permittedInsecurePackages = [ \"dotnet-runtime-6.0.36\" ];" guest_nix_text)
      )
      "src/vms/nixos/guest.nix must force standalone-eval overrides (gcr-ssh-agent, 32-bit graphics, Steam, stateVersion, unfree/insecure policy)";

  # core.nix must append camillagui-backend via ++ (lib.optionals ...) so the
  # overlay-only package is skipped by vanilla nixpkgs evaluations (e.g. the
  # nixos-generators guest build); placing lib.optionals inside the list literal
  # would nest a list element and fail the systemPackages package-type check.
  test_core_nix_guards_overlay_only_packages =
    assert'
      (
        (lib.hasInfix "++ (lib.optionals (pkgs ? camillagui-backend) [ pkgs.camillagui-backend ])" core_nix_text)
        && (lib.hasInfix "vanilla nixpkgs has no such attribute" core_nix_text)
      )
      "src/modules/core.nix must guard camillagui-backend behind a ++ (lib.optionals (pkgs ? camillagui-backend)) concat, not a nested list literal";

  # core.nix must filter overlap packages by meta.available on Linux so
  # arch-specific nixpkgs attrs (e.g. discord-canary, x86_64-linux only) are
  # dropped from aarch64-linux evals like the nixos-generators guest build.
  test_core_nix_overlap_arch_available_filter =
    assert'
      (
        (lib.hasInfix "overlapNixAttrAvailable name" core_nix_text)
        && (lib.hasInfix "overlapNixAttrAvailable =" core_nix_text)
        && (lib.hasInfix "(pkgs.\${attr}.meta.available or true)" core_nix_text)
        && (lib.hasInfix "does NOT trigger check-meta's refusal" core_nix_text)
      )
      "src/modules/core.nix must filter overlap nixpkgs packages by meta.available on Linux (arch-aware, lazy, non-refusing)";

  test_utm_runtime_replacement_requires_valid_prebuilt =
    assert'
      (
        (lib.hasInfix "_prebuilt_valid=false" vm_setup_sh_text)
        && (lib.hasInfix "cannot replace the $vm_name runtime disk because no valid pre-built image is available" vm_setup_sh_text)
      )
      "scripts/vm.sh must refuse to replace UTM runtime disks when the rebuild step did not produce a valid pre-built qcow2";

  # UTM provisioning for Android must treat android-system.qcow2 as the
  # pre-built image (never a nonexistent Android.qcow2), validate it with the
  # relaxed 4 GiB floor, and copy system/userdata/optional-GSI into the bundle.
  test_utm_android_uses_shared_images =
    assert'
      (
        (lib.hasInfix ''_android_system="$IMAGES_DIR/android-system.qcow2"'' vm_setup_sh_text)
        && (lib.hasInfix ''_android_userdata="$IMAGES_DIR/android-userdata.qcow2"'' vm_setup_sh_text)
        && (lib.hasInfix ''_prebuilt="$_android_system"'' vm_setup_sh_text)
        && (lib.hasInfix "_prebuilt_min_size=4294967296" vm_setup_sh_text)
        && (lib.hasInfix "copied Android system image" vm_setup_sh_text)
        && (lib.hasInfix "copied Android userdata disk" vm_setup_sh_text)
        && (lib.hasInfix "Android userdata image not found" vm_setup_sh_text)
      )
      "scripts/vm.sh must provision Android UTM bundles from the shared android-* images with android-system.qcow2 as the prebuilt";

  # The Android build must strip the whitespace wc -c pads its output with
  # (macOS pads, Linux does not); otherwise the size leaks into the selected
  # qcow2 path and cp fails, aborting the build.
  test_android_build_strips_wc_padding =
    assert'
      (
        (lib.hasInfix "wc -c < \"\$_f\" | tr -d '[:space:]'" vm_setup_sh_text)
        && (lib.hasInfix "pick the largest qcow2 as the system image" vm_setup_sh_text)
        && (lib.hasInfix "sort -rn | head -1 | cut -d' ' -f2-" vm_setup_sh_text)
      )
      "scripts/vm.sh must strip wc -c whitespace padding when selecting the largest qcow2 from the extracted LineageOS bundle";

  # The Android build must size the userdata disk from the manifest's
  # diskBytes (SI bytes -> nearest binary GiB, same rounding as
  # vm_build_one_image) instead of a hardcoded 8 GiB; otherwise the
  # VMs.json diskBytes setting is silently ignored.
  test_android_build_honors_manifest_disk_size =
    assert'
      (
        (lib.hasInfix ".VMs[\$_bai_vm_index].diskBytes" vm_setup_sh_text)
        && (lib.hasInfix "_bai_disk_gib=\"\$(( (_bai_disk_bytes + 536870912) / 1073741824 ))\"" vm_setup_sh_text)
        && (lib.hasInfix "qemu-img create -f qcow2 \"\$_bai_userdata_img\" \"\${_bai_disk_gib}G\"" vm_setup_sh_text)
        && (lib.hasInfix "creating userdata disk (\${_bai_disk_gib} GiB)..." vm_setup_sh_text)
      )
      "scripts/vm.sh must size the Android userdata disk from the manifest diskBytes, not a hardcoded 8 GiB";

  test_libvirt_runtime_validation_parity =
    assert'
      (
        (lib.hasInfix "failed to start libvirt default network" vm_setup_sh_text)
        && (lib.hasInfix "failed to mark libvirt default network for autostart" vm_setup_sh_text)
        && (lib.hasInfix "validate_qcow2_image \"$_prebuilt\" \"pre-built image for \${vm_name}\"" vm_setup_sh_text)
        && (lib.hasInfix "validate_qcow2_image \"$disk_path\" \"existing libvirt runtime disk for \${vm_name}\"" vm_setup_sh_text)
        && (lib.hasInfix "existing libvirt runtime disk is invalid" vm_setup_sh_text)
      )
      "scripts/vm.sh must validate libvirt prebuilt/runtime disks and surface default-network recovery failures";

  # Local Mido compatibility adjustments must be applied at runtime from a
  # repository-owned patch file, not by editing the vendored submodule files.
  test_windows_iso_mido_patch_file_exists = assert' (builtins.pathExists ../../src/vms/windows/patches/mido-iso-link.patch) "src/vms/windows/patches/mido-iso-link.patch must exist for runtime Mido patching";
  test_windows_iso_mido_runtime_patch_support =
    assert'
      (
        (lib.hasInfix "NUCLEUS_MIDO_PATCH_FILE" vm_setup_sh_text)
        && (lib.hasInfix "src/vms/windows/patches/mido-iso-link.patch" vm_setup_sh_text)
        && (lib.hasInfix "patch -s" vm_setup_sh_text)
      )
      "scripts/vm.sh must patch a temporary Mido copy at runtime instead of editing vendored submodule files";
  test_windows_iso_mido_patch_failure_is_fatal = assert' (
    (lib.hasInfix "runtime Mido patch failed to apply" vm_setup_sh_text)
    && (lib.hasInfix "install patch and retry" vm_setup_sh_text)
  ) "scripts/vm.sh must fail fast when runtime Mido patching is unavailable or out-of-date";

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
        (lib.hasInfix "<key>Drive</key>" utmConfigPlistText)
        && (lib.hasInfix "<key>ImageName</key>" utmConfigPlistText)
        && (lib.hasInfix "<key>QEMU</key>" utmConfigPlistText)
        && (lib.hasInfix "<key>Input</key>" utmConfigPlistText)
      )
      "src/modules/configs/vms/utm-config.plist.xml must include core UTM schema keys (Drive/ImageName/QEMU/Input) for reliable imports";
  # The Backend value must be exactly "QEMU" (uppercase) — UTM's Swift enum
  # performs a case-sensitive match and throws invalidBackend on any other value.
  # Keep generated templates schema-complete so UTM can decode/import bundles
  # without requiring app-side defaults for missing keys.
  test_macbook_utm_plist_correctness = assert' (
    (lib.hasInfix "<string>QEMU</string>" utmConfigPlistText)
    && (lib.hasInfix "<key>IconCustom</key>" utmConfigPlistText)
    && (lib.hasInfix "<key>Sound</key>" utmConfigPlistText)
    && (lib.hasInfix "<key>DirectoryShareMode</key>" utmConfigPlistText)
    && (lib.hasInfix "<key>ClipboardSharing</key>" utmConfigPlistText)
    && (lib.hasInfix "<key>DirectoryShareReadOnly</key>" utmConfigPlistText)
    && (lib.hasInfix "<key>DownscalingFilter</key>" utmConfigPlistText)
    && (lib.hasInfix "<key>UpscalingFilter</key>" utmConfigPlistText)
    && (lib.hasInfix "<key>NativeResolution</key>" utmConfigPlistText)
    && (lib.hasInfix "<key>MacAddress</key>" utmConfigPlistText)
    && (lib.hasInfix "<key>IsolateFromHost</key>" utmConfigPlistText)
    && (lib.hasInfix "<key>PortForward</key>" utmConfigPlistText)
    && (lib.hasInfix "<string>VirtIO</string>" utmConfigPlistText)
    && (lib.hasInfix "<key>Hypervisor</key>" utmConfigPlistText)
    && (lib.hasInfix "<key>AdditionalArguments</key>" utmConfigPlistText)
    && (lib.hasInfix "<key>BalloonDevice</key>" utmConfigPlistText)
    && (lib.hasInfix "<key>DebugLog</key>" utmConfigPlistText)
    && (lib.hasInfix "<key>PS2Controller</key>" utmConfigPlistText)
    && (lib.hasInfix "<key>RNGDevice</key>" utmConfigPlistText)
    && (lib.hasInfix "<key>RTCLocalTime</key>" utmConfigPlistText)
    && (lib.hasInfix "<key>TPMDevice</key>" utmConfigPlistText)
    && (lib.hasInfix "<key>UEFIBoot</key>" utmConfigPlistText)
    && (lib.hasInfix "<key>MaximumUsbShare</key>" utmConfigPlistText)
    && (lib.hasInfix "<key>UsbBusSupport</key>" utmConfigPlistText)
    && (lib.hasInfix "<key>UsbSharing</key>" utmConfigPlistText)
  ) "src/modules/configs/vms/utm-config.plist.xml must include a schema-complete UTM configuration";
  # The Sound block must be tokenized (__VM_SOUND__) so per-VM guest audio
  # hardware is rendered from vms.nix (Android: empty array).
  test_macbook_utm_sound_token = assert' (lib.hasInfix "__VM_SOUND__" utmConfigPlistText) "src/modules/configs/vms/utm-config.plist.xml must tokenize the Sound block (__VM_SOUND__) so Android can disable guest audio";
  test_macbook_utm_vm_sound_mapping =
    assert'
      (
        (lib.hasInfix "vmSound =" macbook_vms_nix_text)
        && (lib.hasInfix "vm.sound == \"none\"" macbook_vms_nix_text)
        && (lib.hasInfix "<array/>" macbook_vms_nix_text)
        && (lib.hasInfix "<string>intel-hda</string>" macbook_vms_nix_text)
        && (lib.hasInfix "__VM_SOUND__" macbook_vms_nix_text)
      )
      "src/hosts/MacBook/vms.nix must map VM sound ('none' → empty Sound array, default → intel-hda) via the __VM_SOUND__ token";
  test_macbook_utm_no_qemu_guest_agent =
    assert'
      (
        !(lib.hasInfix "qga-" utmConfigPlistText)
        && !(lib.hasInfix "org.qemu.guest_agent.0" utmConfigPlistText)
        && !(lib.hasInfix "-chardev" utmConfigPlistText)
        && (lib.hasInfix "<key>AdditionalArguments</key>" utmConfigPlistText)
      )
      "src/modules/configs/vms/utm-config.plist.xml must not add a QEMU GA chardev: UTM's app sandbox denies binding unix sockets in /tmp (EPERM on boot) and UTM's own bundles omit it";
  # UTM's QEMU backend only emits hostfwd= for Mode=Emulated (user/slirp
  # networking); for Mode=Shared (vmnet-shared) the PortForward array is
  # silently ignored, so SSH (2222) and ADB (5555) become unreachable.  The
  # template must stay on Emulated so vm.sh's guest-wait checks actually work.
  test_macbook_utm_emulated_network_for_port_forward =
    assert'
      (
        (lib.hasInfix "<key>Mode</key>" utmConfigPlistText)
        && (lib.hasInfix "<string>Emulated</string>" utmConfigPlistText)
        && !(lib.hasInfix "<string>Shared</string>" utmConfigPlistText)
        && (lib.hasInfix "<key>PortForward</key>" utmConfigPlistText)
        && (lib.hasInfix "__VM_BASE_PORT_FORWARD__" utmConfigPlistText)
        && (lib.hasInfix "__VM_ADDITIONAL_PORT_FORWARDS__" utmConfigPlistText)
      )
      "src/modules/configs/vms/utm-config.plist.xml must use Mode=Emulated (not Shared) so UTM forwards ports 2222/5555 via hostfwd; vmnet-shared silently drops PortForward";
  # Android must not claim host port 2222: it exposes ADB and SSH on forwarded
  # ports 5555/5554, and a base 2222->22 forward would collide with NixOS when
  # both VMs run at once ("Could not set up host forwarding rule" on the second
  # start).  The base forward is a per-VM token so each VM only binds its own
  # host ports.
  test_macbook_utm_android_no_2222_collision =
    assert'
      (
        (lib.hasInfix "basePortForward =\n    vm:\n    if vm.type == \"Android\" then\n      \"\"" macbook_vms_nix_text)
        && (lib.hasInfix "<integer>2222</integer>" macbook_vms_nix_text)
        && (lib.hasInfix "__VM_BASE_PORT_FORWARD__\n                __VM_ADDITIONAL_PORT_FORWARDS__" utmConfigPlistText)
      )
      "src/hosts/MacBook/vms.nix must gate the base 2222->22 forward off for Android (which uses 5555/5554) so simultaneous Android+NixOS starts do not collide on host port 2222";
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
      "scripts/vm.sh must place UTM disk-main.qcow2 under bundle Data/ to match ImageName-based UTM drive resolution";
  test_macbook_utm_uses_direct_bundle_open =
    assert'
      (
        (lib.hasInfix "open \"$bundle\"" vm_setup_sh_text)
        && !(lib.hasInfix "osascript -e" vm_setup_sh_text)
        && !(lib.hasInfix "import new virtual machine from POSIX file" vm_setup_sh_text)
        && (lib.hasInfix "opening UTM bundle in place" vm_setup_sh_text)
      )
      "scripts/vm.sh must open the managed .utm bundle directly instead of importing it into a copied UTM storage tree";
  test_macbook_utm_refreshes_existing_bundle =
    assert'
      (
        (lib.hasInfix "refreshing config.plist" vm_setup_sh_text)
        && !(lib.hasInfix "UTM bundle already exists: %s; skipping" vm_setup_sh_text)
      )
      "scripts/vm.sh must refresh config.plist for existing UTM bundles so schema fixes apply without deleting bundles";
  test_macbook_utm_stale_template_guard = assert' (
    (lib.hasInfix "stale UTM template detected" vm_setup_sh_text)
    && (lib.hasInfix "run home-manager switch (or nucleus apply) before vm-setup" vm_setup_sh_text)
  ) "scripts/vm.sh must fail fast on stale UTM templates and print the recovery action";
  test_macbook_utm_required_key_guard = assert' (
    (lib.hasInfix "_required_utm_keys" vm_setup_sh_text)
    && (lib.hasInfix "_missing_utm_keys" vm_setup_sh_text)
    && (lib.hasInfix "stale or incomplete UTM template detected" vm_setup_sh_text)
    && (lib.hasInfix "<key>IconCustom</key>" vm_setup_sh_text)
    && (lib.hasInfix "<key>UsbBusSupport</key>" vm_setup_sh_text)
  ) "scripts/vm.sh must block incomplete UTM templates missing required keys";
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
      "scripts/vm.sh must re-register UTM VMs when legacy display configs or template drift are detected so refreshed config.plist values take effect";
  test_vm_readme_template_content =
    assert'
      (
        (lib.hasInfix "nucleus-vm setup" readmeTemplateText)
        && (lib.hasInfix "## Layout" readmeTemplateText)
        && (lib.hasInfix "<name>-build/" readmeTemplateText)
        && (lib.hasInfix "<name>-installer.iso" readmeTemplateText)
        && (lib.hasInfix "## Start commands" readmeTemplateText)
        && (lib.hasInfix "start-<name>.sh" readmeTemplateText)
        && (lib.hasInfix "start-<name>.ps1" readmeTemplateText)
        && (lib.hasInfix "## UTM bundle portability" readmeTemplateText)
        && (lib.hasInfix "Copying only `config.plist`" readmeTemplateText)
        && (lib.hasInfix "## Guest configuration" readmeTemplateText)
        && (lib.hasInfix "## Lifecycle" readmeTemplateText)
        && (lib.hasInfix "## Safe cleanup" readmeTemplateText)
        && (lib.hasInfix "## Troubleshooting" readmeTemplateText)
        && (lib.hasInfix "__VM_DIR_DISPLAY__" readmeTemplateText)
        && (lib.hasInfix "__IMAGES_DIR_DISPLAY__" readmeTemplateText)
        && (!lib.hasInfix "{{" readmeTemplateText)
        && (lib.hasInfix "## Notes" readmeTemplateText)
      )
      "src/vms/templates/README.md must contain all expected documentation sections and __TOKEN__ placeholders, with no {{TOKEN}} style";

  test_vm_start_posix_template_content = assert' (
    (lib.hasInfix "__VM_NAME__" startPosixTemplateText)
    && (lib.hasInfix "__VM_DISPLAY__" startPosixTemplateText)
    && (lib.hasInfix "__HOST_KIND__" startPosixTemplateText)
    && (lib.hasInfix "__VM_DIR__" startPosixTemplateText)
    && (lib.hasInfix "darwin-tart" startPosixTemplateText)
    && (lib.hasInfix "darwin-utm" startPosixTemplateText)
    && (lib.hasInfix "nixos-libvirt" startPosixTemplateText)
    && (lib.hasInfix "tart run" startPosixTemplateText)
    && (lib.hasInfix "utmctl" startPosixTemplateText)
    && (lib.hasInfix "virsh start" startPosixTemplateText)
    && (lib.hasInfix "virt-viewer" startPosixTemplateText)
  ) "src/vms/templates/start-posix.sh must contain all expected placeholders and runtime branches";

  # The PowerShell host-side start/stop helpers are single shared dispatcher
  # templates (embedded-content policy), one per file kind, with __TOKEN__
  # placeholders for the host kind and VM attributes substituted by vm.sh.
  test_vm_start_host_ps1_template_content =
    assert'
      (
        (lib.hasInfix "__HOST_KIND__" startHostPs1TemplateText)
        && (lib.hasInfix "__VM_NAME__" startHostPs1TemplateText)
        && (lib.hasInfix "__VM_DISPLAY__" startHostPs1TemplateText)
        && (lib.hasInfix "__VM_DIR__" startHostPs1TemplateText)
        && (lib.hasInfix "switch ('__HOST_KIND__')" startHostPs1TemplateText)
        && (lib.hasInfix "darwin-tart" startHostPs1TemplateText)
        && (lib.hasInfix "darwin-utm" startHostPs1TemplateText)
        && (lib.hasInfix "nixos-libvirt" startHostPs1TemplateText)
        && (lib.hasInfix "tart run" startHostPs1TemplateText)
        && (lib.hasInfix "utmctl" startHostPs1TemplateText)
        && (lib.hasInfix "virsh start" startHostPs1TemplateText)
        && (lib.hasInfix "virt-viewer" startHostPs1TemplateText)
        && (!lib.hasInfix "{{" startHostPs1TemplateText)
      )
      "src/vms/templates/start-host.ps1 must be a single dispatcher with all expected placeholders and runtime branches, with no {{TOKEN}} style";

  test_vm_stop_posix_template_content =
    assert'
      (
        (lib.hasInfix "__HOST_KIND__" stopPosixShTemplateText)
        && (lib.hasInfix "__VM_NAME__" stopPosixShTemplateText)
        && (lib.hasInfix "__VM_DISPLAY__" stopPosixShTemplateText)
        && (lib.hasInfix "case \"$HOST_KIND\"" stopPosixShTemplateText)
        && (lib.hasInfix "tart stop" stopPosixShTemplateText)
        && (lib.hasInfix "utmctl stop" stopPosixShTemplateText)
        && (lib.hasInfix "virsh shutdown" stopPosixShTemplateText)
        && (lib.hasInfix "virsh destroy" stopPosixShTemplateText)
        && (lib.hasInfix "set -eu" stopPosixShTemplateText)
        && (!lib.hasInfix "{{" stopPosixShTemplateText)
      )
      "src/vms/templates/stop-posix.sh must be a single dispatcher with all expected placeholders and runtime branches, with no {{TOKEN}} style";

  test_vm_stop_host_ps1_template_content =
    assert'
      (
        (lib.hasInfix "__HOST_KIND__" stopHostPs1TemplateText)
        && (lib.hasInfix "__VM_NAME__" stopHostPs1TemplateText)
        && (lib.hasInfix "#Requires -Version 7.4" stopHostPs1TemplateText)
        && (lib.hasInfix "tart stop" stopHostPs1TemplateText)
        && (lib.hasInfix "utmctl stop" stopHostPs1TemplateText)
        && (lib.hasInfix "virsh shutdown" stopHostPs1TemplateText)
        && (lib.hasInfix "virsh destroy" stopHostPs1TemplateText)
        && (lib.hasInfix "qga-" stopHostPs1TemplateText)
        && (lib.hasInfix "Stop-Process -Force" stopHostPs1TemplateText)
        && (!lib.hasInfix "{{" stopHostPs1TemplateText)
        && (!lib.hasInfix "`$ErrorActionPreference" stopHostPs1TemplateText)
      )
      "src/vms/templates/stop-host.ps1 must be a single dispatcher with all expected placeholders and runtime branches, no {{TOKEN}} style, and no backtick-escaped statement dollars";

  # Every __TOKEN__ in the host-kind templates must have a sed replacement in
  # vm.sh so no placeholder survives into a rendered helper script.
  test_vm_host_templates_render_chains =
    assert'
      (
        (lib.hasInfix "s|__HOST_KIND__|" vm_setup_sh_text)
        && (lib.hasInfix "s|__VM_NAME__|" vm_setup_sh_text)
        && (lib.hasInfix "s|__VM_DISPLAY__|" vm_setup_sh_text)
        && (lib.hasInfix "s|__VM_DIR__|" vm_setup_sh_text)
        && (lib.hasInfix "start-host.ps1" vm_setup_sh_text)
        && (lib.hasInfix "stop-posix.sh" vm_setup_sh_text)
        && (lib.hasInfix "stop-host.ps1" vm_setup_sh_text)
      )
      "vm.sh must render start-host.ps1/stop-posix.sh/stop-host.ps1 via sed token chains that cover all template placeholders";

  test_vm_start_windows_template_content =
    assert'
      (
        (lib.hasInfix "__QEMU_SYSTEM__" startWindowsTemplateText)
        && (lib.hasInfix "__VM_DISPLAY__" startWindowsTemplateText)
        && (lib.hasInfix "__MACHINE__" startWindowsTemplateText)
        && (lib.hasInfix "__CPU__" startWindowsTemplateText)
        && (lib.hasInfix "__CPUS__" startWindowsTemplateText)
        && (lib.hasInfix "__RAM_MIB__" startWindowsTemplateText)
        && (lib.hasInfix "__DISK_PATH__" startWindowsTemplateText)
        && (lib.hasInfix "__VGA__" startWindowsTemplateText)
        && (lib.hasInfix "__DISPLAY_BACKEND__" startWindowsTemplateText)
        && (lib.hasInfix "__VIRTIOFS_ARGS__" startWindowsTemplateText)
        && (lib.hasInfix "org.qemu.guest_agent.0" startWindowsTemplateText)
        && (lib.hasInfix "hostfwd=tcp::2222-:22" startWindowsTemplateText)
        && (lib.hasInfix "chardev pipe" startWindowsTemplateText)
        && (!lib.hasInfix "{{" startWindowsTemplateText)
      )
      "src/vms/templates/start-windows.ps1 must contain all expected __TOKEN__ placeholders and QEMU arguments, with no {{TOKEN}} style";

  test_vm_start_windows_host_template_content =
    assert'
      (
        (lib.hasInfix "__QEMU_SYSTEM__" startWindowsHostTemplateText)
        && (lib.hasInfix "__VM_NAME__" startWindowsHostTemplateText)
        && (lib.hasInfix "__VM_DISPLAY__" startWindowsHostTemplateText)
        && (lib.hasInfix "__MACHINE__" startWindowsHostTemplateText)
        && (lib.hasInfix "__CPU__" startWindowsHostTemplateText)
        && (lib.hasInfix "__CPUS__" startWindowsHostTemplateText)
        && (lib.hasInfix "__RAM_MIB__" startWindowsHostTemplateText)
        && (lib.hasInfix "__DISK_PATH__" startWindowsHostTemplateText)
        && (lib.hasInfix "__VGA__" startWindowsHostTemplateText)
        && (lib.hasInfix "__DISPLAY_BACKEND__" startWindowsHostTemplateText)
        && (lib.hasInfix "org.qemu.guest_agent.0" startWindowsHostTemplateText)
        && (lib.hasInfix "hostfwd=tcp::2222-:22" startWindowsHostTemplateText)
        && (lib.hasInfix "chardev pipe" startWindowsHostTemplateText)
        && (lib.hasInfix "set -eu" startWindowsHostTemplateText)
        && (!lib.hasInfix "{{" startWindowsHostTemplateText)
      )
      "src/vms/templates/start-windows-host.sh must contain all expected __TOKEN__ placeholders and QEMU arguments, with no {{TOKEN}} style";

  test_vm_directory_readme_generation =
    assert'
      (
        (lib.hasInfix "write_vm_directory_readme" vm_setup_sh_text)
        && (lib.hasInfix "wrote VM directory guide" vm_setup_sh_text)
        && (lib.hasInfix "TEMPLATES_DIR/README.md" vm_setup_sh_text)
        && (lib.hasInfix "__VM_DIR_DISPLAY__" readmeTemplateText)
        && (lib.hasInfix "__IMAGES_DIR_DISPLAY__" readmeTemplateText)
        && (lib.hasInfix "## Start commands" readmeTemplateText)
        && (lib.hasInfix "## Safe cleanup" readmeTemplateText)
        && (lib.hasInfix "UTM bundle" readmeTemplateText)
      )
      "scripts/vm.sh must write ~/virtual machines/README.md using the cross-host README template with placeholder substitution";
  test_windows_vm_directory_readme_generation =
    assert'
      (
        (lib.hasInfix "$vmReadmePath = Join-Path $vmDir 'README.md'" windows_vm_setup_ps1_text)
        && (lib.hasInfix "VM directory guide written" windows_vm_setup_ps1_text)
        && (lib.hasInfix "templatesDir" windows_vm_setup_ps1_text)
        && (lib.hasInfix "nucleus-vm setup" readmeTemplateText)
        && (lib.hasInfix "## Start commands" readmeTemplateText)
        && (lib.hasInfix "## Safe cleanup" readmeTemplateText)
        && (lib.hasInfix "UTM bundle" readmeTemplateText)
      )
      "Invoke-VMSetup.ps1 must write %USERPROFILE%\\virtual machines\\README.md using the cross-host README template with placeholder substitution";
  test_vm_setup_generates_helper_scripts = assert' (lib.hasInfix "write_start_script" vm_setup_sh_text) "VM setup flows must generate discoverable start helper scripts";
  test_macbook_utm_default_location_link = assert' (
    (lib.hasInfix "ensure_utm_default_vm_location" vm_setup_sh_text)
    && (lib.hasInfix "$HOME/Library/Containers/com.utmapp.UTM/Data/Documents" vm_setup_sh_text)
    && (lib.hasInfix "linked UTM default VM location" vm_setup_sh_text)
  ) "scripts/vm.sh must best-effort wire UTM's sandboxed document location to ~/virtual machines";

  test_vm_enabled_policy_wiring = assert' (
    (lib.hasInfix "\"enabled\"" vms_json_text)
    && (lib.hasInfix ".VMs[$_i].enabled" vm_setup_sh_text)
    && (lib.hasInfix "disabled in manifest; skipping" vm_setup_sh_text)
    && (lib.hasInfix "function Test-VMEnabled" windows_vm_setup_ps1_text)
    && (lib.hasInfix "$Vm.enabled -isnot [bool]" windows_vm_setup_ps1_text)
    && (lib.hasInfix "enabledVms = builtins.filter (" macbook_vms_nix_text)
    && (lib.hasInfix "enabledVms = builtins.filter (" (builtins.readFile ../../src/hosts/NixOS/vms.nix))
  ) "VM enable/disable policy must be wired in manifest, setup scripts, and host template generation";

  # The Android GSI drive must be rendered only when androidGsiUrl is set
  # (the manifest permits null); a revert to unconditional GSI emission must
  # fail. The userdata drive stays attached unconditionally.
  test_macbook_android_gsi_conditional =
    assert'
      (
        (lib.hasInfix "androidGsiUrl != null" macbook_vms_nix_text)
        && (lib.hasInfix "android-gsi.img" macbook_vms_nix_text)
        && (lib.hasInfix "android-userdata.qcow2" macbook_vms_nix_text)
      )
      "src/hosts/MacBook/vms.nix must render the GSI drive only when androidGsiUrl is non-null while keeping android-userdata.qcow2 attached unconditionally";

  # The Android drive token must be emitted inside the Drive array (before
  # </array>); an emission outside the array produces orphan <dict> entries at
  # the plist top level, yielding a malformed config.plist that UTM silently
  # rejects on import (the bundle never registers).
  test_utm_android_drives_inside_drive_array =
    assert'
      (
        (lib.hasInfix "__VM_ANDROID_DRIVES__\n    </array>\n    <key>Display</key>" utmConfigPlistText)
        && !(lib.hasInfix "</array>\n    __VM_ANDROID_DRIVES__" utmConfigPlistText)
      )
      "src/modules/configs/vms/utm-config.plist.xml must emit __VM_ANDROID_DRIVES__ inside the Drive array so Android dict entries are valid array elements";

  # NixOS libvirt domain XML must attach the GSI disk only when
  # androidGsiUrl is set, mirroring the MacBook UTM template.
  test_nixos_android_gsi_conditional = assert' (
    (lib.hasInfix "androidGsiUrl != null" nixos_vms_nix_text)
    && (lib.hasInfix "images/android-gsi.img" nixos_vms_nix_text)
  ) "src/hosts/NixOS/vms.nix must render the GSI disk only when androidGsiUrl is non-null";

  # NixOS Android system/userdata disks must live under images/ inside the VM
  # directory; bare ${vmDir}/android-*.qcow2 paths would break the cross-host
  # images layout.
  test_nixos_android_disk_paths_in_images_dir =
    assert'
      (
        (lib.hasInfix "images/android-system.qcow2" nixos_vms_nix_text)
        && (lib.hasInfix "images/android-userdata.qcow2" nixos_vms_nix_text)
        && !(lib.hasInfix "\${vmDir}/android-system.qcow2" nixos_vms_nix_text)
        && !(lib.hasInfix "\${vmDir}/android-userdata.qcow2" nixos_vms_nix_text)
      )
      "src/hosts/NixOS/vms.nix must place Android system/userdata disks under \${vmDir}/images/ and never at the bare VM directory root";

  test_macbook_tart_storage_link =
    assert'
      (
        (lib.hasInfix "ensure_tart_vm_dir" vm_setup_sh_text)
        && (lib.hasInfix "/.tart" vm_setup_sh_text)
        && (lib.hasInfix "linked tart storage" vm_setup_sh_text)
        && (lib.hasInfix "rsync" vm_setup_sh_text)
      )
      "scripts/vm.sh must link ~/.tart -> ~/virtual machines/.tart so Tart artifacts co-locate with UTM bundles for backup";

  test_macbook_macos_version_tahoe =
    assert'
      (
        (lib.hasInfix "\"macOSVersion\": \"tahoe\"" vms_json_text)
        && (lib.hasInfix "[-var macos_version=tahoe]" vms_macos_packer_text)
        && (lib.hasInfix "default     = \"tahoe\"" vms_macos_packer_text)
        && (lib.hasInfix "macOS version to provision (tahoe, sequoia, sonoma, ventura, etc.)" vms_macos_packer_text)
        && (lib.hasInfix "tahoe" vm_setup_sh_text)
      )
      "MacBook macOS guest version must default to Tahoe across VMs.json, vm.sh, and the macOS Packer template";

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
      "scripts/vm.sh must attempt a non-Windows Fido URL fallback first on Darwin/Linux, with Mido as secondary fallback and retry support";

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
    test_enabled_types
    test_windows_iso_url_type
    test_macos_version_type
    test_windows_edition_type
    test_hosts_field
    test_plist_uuid_format
    test_plist_uuid_uniqueness
    test_domain_xml_kvm_type
    test_domain_xml_memory_unit
    test_domain_xml_disk_path_lowercase
    test_packer_templates_exist
    test_vm_templates_exist
    test_vm_setup_scripts_exist
    test_guest_nix_nonempty
    test_nixos_guest_virtiofs_not_forced
    test_nixos_guest_qemu_guest_enabled
    test_nixos_guest_openssh_enabled
    test_nixos_guest_nucleus_rebuild_service
    test_nixos_guest_ssh_authorized_keys
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
    test_windows_packer_ssh_port_forward
    test_windows_autounattend_ssh_before_virtio
    test_windows_autounattend_bios_system_partition_type
    test_guest_credentials_policy_in_user_registries
    test_guest_credentials_policy_in_user_secrets
    test_guest_credentials_policy_in_vm_setup_sh
    test_nixos_generators_uses_exported_env_credentials
    test_guest_credentials_policy_in_windows_vm_setup_ps1
    test_guest_credentials_policy_in_nixos_guest
    test_guest_credentials_policy_in_nixos_packer
    test_windows_nixos_build_honors_manifest_disk_size
    test_guest_credentials_policy_in_windows_packer
    test_guest_credentials_policy_in_windows_autounattend
    test_guest_credentials_policy_in_macos_packer
    test_vm_guest_credential_drift_replacement
    test_utm_runtime_replacement_requires_valid_prebuilt
    test_utm_android_uses_shared_images
    test_android_build_strips_wc_padding
    test_android_build_honors_manifest_disk_size
    test_libvirt_runtime_validation_parity
    test_windows_iso_mido_patch_file_exists
    test_windows_iso_mido_runtime_patch_support
    test_windows_iso_mido_patch_failure_is_fatal
    test_macbook_utm_windows_arch_override
    test_macbook_utm_schema_keys
    test_macbook_utm_plist_correctness
    test_macbook_utm_no_qemu_guest_agent
    test_macbook_utm_emulated_network_for_port_forward
    test_macbook_utm_android_no_2222_collision
    test_macbook_utm_display_card_validity
    test_macbook_utm_firmware_contract
    test_macbook_utm_data_dir_disk_path
    test_macbook_utm_uses_direct_bundle_open
    test_macbook_utm_refreshes_existing_bundle
    test_macbook_utm_stale_template_guard
    test_macbook_utm_legacy_display_reregistration
    test_vm_readme_template_content
    test_vm_start_posix_template_content
    test_vm_start_windows_template_content
    test_vm_start_windows_host_template_content
    test_vm_start_host_ps1_template_content
    test_vm_stop_posix_template_content
    test_vm_stop_host_ps1_template_content
    test_vm_host_templates_render_chains
    test_vm_directory_readme_generation
    test_windows_vm_directory_readme_generation
    test_vm_setup_generates_helper_scripts
    test_macbook_utm_default_location_link
    test_macbook_tart_storage_link
    test_vm_enabled_policy_wiring
    test_macbook_android_gsi_conditional
    test_utm_android_drives_inside_drive_array
    test_nixos_android_gsi_conditional
    test_nixos_android_disk_paths_in_images_dir
    test_macbook_macos_version_tahoe
    test_windows_iso_fido_nonwindows_fallback
    test_android_gsi_url_type
    test_android_gsi_url_only_on_android
    test_enabled_vm_not_orphaned
    test_vm_gc_preserves_disabled_entries_by_default
    test_vm_gc_disabled_option_pair
    test_windows_vm_gc_preserves_disabled_entries_by_default
    test_nixos_guest_import_paths_resolve
    test_nixos_guest_config_drift_rebuild
    test_nixos_guest_avoids_host_sops_modules
    test_nixos_guest_threads_username_arg
    test_nixos_guest_standalone_eval_overrides
    test_core_nix_guards_overlay_only_packages
    test_core_nix_overlap_arch_available_filter
    test_macbook_utm_required_key_guard
    test_android_sound_disabled
    test_macbook_utm_sound_token
    test_macbook_utm_vm_sound_mapping
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
    test_enabled_types
    test_windows_iso_url_type
    test_macos_version_type
    test_windows_edition_type
    test_hosts_field
    test_plist_uuid_format
    test_plist_uuid_uniqueness
    test_domain_xml_kvm_type
    test_domain_xml_memory_unit
    test_domain_xml_disk_path_lowercase
    test_packer_templates_exist
    test_vm_templates_exist
    test_vm_setup_scripts_exist
    test_guest_nix_nonempty
    test_nixos_guest_virtiofs_not_forced
    test_nixos_guest_qemu_guest_enabled
    test_nixos_guest_openssh_enabled
    test_nixos_guest_nucleus_rebuild_service
    test_nixos_guest_ssh_authorized_keys
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
    test_windows_packer_ssh_port_forward
    test_windows_autounattend_ssh_before_virtio
    test_windows_autounattend_bios_system_partition_type
    test_guest_credentials_policy_in_user_registries
    test_guest_credentials_policy_in_user_secrets
    test_guest_credentials_policy_in_vm_setup_sh
    test_nixos_generators_uses_exported_env_credentials
    test_guest_credentials_policy_in_windows_vm_setup_ps1
    test_guest_credentials_policy_in_nixos_guest
    test_guest_credentials_policy_in_nixos_packer
    test_windows_nixos_build_honors_manifest_disk_size
    test_guest_credentials_policy_in_windows_packer
    test_guest_credentials_policy_in_windows_autounattend
    test_guest_credentials_policy_in_macos_packer
    test_vm_guest_credential_drift_replacement
    test_utm_runtime_replacement_requires_valid_prebuilt
    test_utm_android_uses_shared_images
    test_android_build_strips_wc_padding
    test_android_build_honors_manifest_disk_size
    test_libvirt_runtime_validation_parity
    test_windows_iso_mido_patch_file_exists
    test_windows_iso_mido_runtime_patch_support
    test_windows_iso_mido_patch_failure_is_fatal
    test_macbook_utm_windows_arch_override
    test_macbook_utm_schema_keys
    test_macbook_utm_plist_correctness
    test_macbook_utm_no_qemu_guest_agent
    test_macbook_utm_emulated_network_for_port_forward
    test_macbook_utm_android_no_2222_collision
    test_macbook_utm_display_card_validity
    test_macbook_utm_firmware_contract
    test_macbook_utm_data_dir_disk_path
    test_macbook_utm_uses_direct_bundle_open
    test_macbook_utm_refreshes_existing_bundle
    test_macbook_utm_stale_template_guard
    test_macbook_utm_legacy_display_reregistration
    test_vm_readme_template_content
    test_vm_start_posix_template_content
    test_vm_start_windows_template_content
    test_vm_start_windows_host_template_content
    test_vm_start_host_ps1_template_content
    test_vm_stop_posix_template_content
    test_vm_stop_host_ps1_template_content
    test_vm_host_templates_render_chains
    test_vm_directory_readme_generation
    test_windows_vm_directory_readme_generation
    test_vm_setup_generates_helper_scripts
    test_macbook_utm_default_location_link
    test_macbook_tart_storage_link
    test_vm_enabled_policy_wiring
    test_macbook_android_gsi_conditional
    test_utm_android_drives_inside_drive_array
    test_nixos_android_gsi_conditional
    test_nixos_android_disk_paths_in_images_dir
    test_macbook_macos_version_tahoe
    test_windows_iso_fido_nonwindows_fallback
    test_android_gsi_url_type
    test_android_gsi_url_only_on_android
    test_enabled_vm_not_orphaned
    test_vm_gc_preserves_disabled_entries_by_default
    test_vm_gc_disabled_option_pair
    test_windows_vm_gc_preserves_disabled_entries_by_default
    test_nixos_guest_import_paths_resolve
    test_nixos_guest_config_drift_rebuild
    test_nixos_guest_avoids_host_sops_modules
    test_nixos_guest_threads_username_arg
    test_nixos_guest_standalone_eval_overrides
    test_core_nix_guards_overlay_only_packages
    test_core_nix_overlap_arch_available_filter
    test_macbook_utm_required_key_guard
    test_android_sound_disabled
    test_macbook_utm_sound_token
    test_macbook_utm_vm_sound_mapping
    ;

  summary = builtins.deepSeq all_tests "vm-setup-tests: all tests passed";
}
