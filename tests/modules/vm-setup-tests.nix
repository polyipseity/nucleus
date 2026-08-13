# tests/modules/vm-setup-tests.nix — VM provisioning manifest and NixOS module options.

let
  lib = import <nixpkgs/lib>;
  inherit (import ../lib.nix) assert' containsRegex;

  manifest = builtins.fromJSON (builtins.readFile ../../src/modules/VMs.json);

  # Deterministic identity derivation, shared with src/hosts/MacBook/vms.nix.
  vmIdentity = import ../../src/modules/lib/vm-identity.nix;

  # Required fields for every VM entry.
  requiredFields = [
    "id"
    "name"
    "type"
    "enabled"
    "hosts"
    "cpus"
    "ram"
    "diskSize"
    "shareDevDir"
    "sound"
    "portForwards"
    "hostname"
    "minImageSize"
    "macAddressPrefix"
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

  # Disk sizes must be suffixed size strings that parse to positive bytes.
  test_disk_sizes =
    let
      badDisks = builtins.filter (vm: size.parse vm.diskSize <= 0) manifest.VMs;
    in
    assert' (badDisks == [ ])
      "Every VM must have diskSize parsing to > 0 bytes; bad entries: ${
        builtins.toString (builtins.map (v: v.name) badDisks)
      }";

  # RAM sizes must be suffixed size strings that parse to positive bytes.
  test_ram_sizes =
    let
      badRam = builtins.filter (vm: size.parse vm.ram <= 0) manifest.VMs;
    in
    assert' (badRam == [ ])
      "Every VM must have ram parsing to > 0 bytes; bad entries: ${
        builtins.toString (builtins.map (v: v.name) badRam)
      }";

  # ---------------------------------------------------------------------------
  # Phase 2 — VM sizes are suffixed strings (kB/MB/GB/TB and kiB/MiB/GiB/TiB)
  # ---------------------------------------------------------------------------
  # The Nix parser (src/modules/lib/size.nix) is the reference implementation;
  # src/scripts/lib/size.sh and src/platforms/Windows/modules/SizeStrings.ps1 must
  # accept and reject exactly the same inputs.  Grammar parity is enforced
  # textually by test_size_grammar_parity_across_implementations; functional
  # acceptance/rejection is pinned on the reference parser below.
  size = import ../../src/modules/lib/size.nix;
  sizePrefixes = [
    "kB"
    "MB"
    "GB"
    "TB"
    "kiB"
    "MiB"
    "GiB"
    "TiB"
  ];
  sizeSchemaPattern = "\"pattern\": \"^[0-9]+ ?(kB|MB|GB|TB|kiB|MiB|GiB|TiB)$\"";
  size_accept_fixtures = [
    {
      input = "8GB";
      bytes = 8000000000;
    }
    {
      input = "8 GB";
      bytes = 8000000000;
    }
    {
      input = "8192MiB";
      bytes = 8589934592;
    }
    {
      input = "1GiB";
      bytes = 1073741824;
    }
    {
      input = "512MB";
      bytes = 512000000;
    }
    {
      input = "512MiB";
      bytes = 536870912;
    }
    {
      input = "1kB";
      bytes = 1000;
    }
    {
      input = "1kiB";
      bytes = 1024;
    }
    {
      input = "1TB";
      bytes = 1000000000000;
    }
    {
      input = "1TiB";
      bytes = 1099511627776;
    }
    {
      input = "0GB";
      bytes = 0;
    }
  ];
  size_reject_inputs = [
    "8KB"
    "8KiB"
    "8gb"
    "8GBi"
    "8B"
    "B"
    "8"
    "8G"
    "8 MB "
    " GB"
    "8MBK"
  ];
  size_sh_text = builtins.readFile ../../src/scripts/lib/size.sh;
  size_ps_text = builtins.readFile ../../src/platforms/Windows/modules/SizeStrings.ps1;
  vms_schema_text = builtins.readFile ../../src/modules/VMs.schema.json;

  test_size_parser_accepts = assert' (builtins.all (f: size.parse f.input == f.bytes)
    size_accept_fixtures
  ) "size.parse must accept every canonical suffixed size string and return the exact byte count";

  test_size_parser_rejects =
    assert' (builtins.all (input: !(builtins.tryEval (size.parse input)).success) size_reject_inputs)
      "size.parse must abort on invalid size strings (capital K, lowercase prefix, bare numbers, missing prefix, trailing junk)";

  test_size_ceil_mib =
    assert'
      (
        (size.ceilMib 8000000000 == 7630)
        && (size.ceilMib 8589934592 == 8192)
        && (size.ceilMib 1073741824 == 1024)
        && (size.ceilMib 7999540000 == 7629)
      )
      "size.ceilMib must round UP so allocated memory never under-allocates (8GB -> 7630 MiB, not 7629)";

  # Grammar parity: all three parsers plus the schema must support the same
  # canonical prefix set.  Textual hasInfix keeps the gate language-agnostic
  # (each implementation escapes its own regex metacharacters).
  test_size_grammar_parity_across_implementations =
    assert'
      (
        builtins.all (p: lib.hasInfix p (builtins.readFile ../../src/modules/lib/size.nix)) sizePrefixes
        && builtins.all (p: lib.hasInfix p size_sh_text) sizePrefixes
        && builtins.all (p: lib.hasInfix p size_ps_text) sizePrefixes
        && builtins.all (p: lib.hasInfix p vms_schema_text) sizePrefixes
      )
      "size.nix, size.sh, SizeStrings.ps1 and VMs.schema.json must all support the same canonical prefix set (kB MB GB TB kiB MiB GiB TiB)";

  # The schema must declare the identical suffixed-size pattern for ram,
  # diskSize and minImageSize (3 occurrences -> 4 splitString parts).
  test_size_schema_pattern =
    assert' (builtins.length (lib.splitString sizeSchemaPattern vms_schema_text) == 4)
      "VMs.schema.json must declare the canonical size-string pattern for ram, diskSize and minImageSize";

  test_manifest_sizes_are_suffixed_strings = assert' (builtins.all (
    vm: builtins.isString vm.ram && builtins.isString vm.diskSize
  ) manifest.VMs) "Every VM must declare ram and diskSize as suffixed size strings";

  test_manifest_sizes_match_pattern = assert' (builtins.all (
    vm:
    builtins.match "^[0-9]+ ?(kB|MB|GB|TB|kiB|MiB|GiB|TiB)$" vm.ram != null
    && builtins.match "^[0-9]+ ?(kB|MB|GB|TB|kiB|MiB|GiB|TiB)$" vm.diskSize != null
  ) manifest.VMs) "Every VM ram/diskSize must match the suffixed-size grammar";

  # Manifest values stay canonical decimal (no embedded spaces, no binary
  # prefixes) so all hosts present identical numbers.
  test_manifest_size_values_are_canonical = assert' (
    builtins.all (vm: builtins.match "^[0-9]+(GB|TB)$" vm.ram != null) manifest.VMs
    && builtins.all (vm: builtins.match "^[0-9]+(GB|TB)$" vm.diskSize != null) manifest.VMs
  ) "Manifest ram/diskSize values must be canonical decimal GB/TB";

  # Status listing must parse the suffixed ram string and display decimal GB.
  test_vm_status_display_parses_suffixed_ram = assert' (
    (lib.hasInfix "ram_bytes=\"\$(parse_size \"\$ram\")\"" vm_setup_sh_text)
    && (lib.hasInfix "ram_gib=\"\$(((ram_bytes + 500000000) / 1000000000))\"" vm_setup_sh_text)
    && (lib.hasInfix ".ram, .id] | @tsv" vm_setup_sh_text)
    && (lib.hasInfix "ConvertFrom-SizeString \$vm.ram" vm_ps1_text)
  ) "scripts/vm.sh and vm.ps1 status must parse the suffixed ram value and display decimal GB";

  # Tart accepts only whole GiB (decimal for `tart create --disk-size`, MB via
  # the packer plugin's GiB*1024 passthrough for `tart set --memory`).  The
  # macOS build must round UP from exact manifest bytes so allocated capacity
  # never under-allocates the declared size.
  test_macos_packer_ceil_units =
    assert'
      (
        (lib.hasInfix "vm_build_macos TYPE DISK_BYTES RAM_BYTES" vm_setup_sh_text)
        && (lib.hasInfix "_disk_gib=\"\$(((_disk_bytes + 999999999) / 1000000000))\"" vm_setup_sh_text)
        && (lib.hasInfix "_mem_gib=\"\$(((_ram_bytes + 1073741823) / 1073741824))\"" vm_setup_sh_text)
        && (lib.hasInfix "-var \"disk_size_gib=\$_disk_gib\"" vm_setup_sh_text)
        && (lib.hasInfix "-var \"memory_gib=\$_mem_gib\"" vm_setup_sh_text)
      )
      "vm.sh must round manifest RAM/disk bytes UP to whole GiB for the Tart Packer build (tart accepts integer GB/MB only)";

  # Image validation floors must derive from the manifest's minImageSize, not
  # hardcoded byte constants.
  test_min_image_size_floor_wiring =
    assert'
      (
        (lib.hasInfix "_prebuilt_min_size=\"\$(parse_size \"\$(jq -r \".VMs[\$vm_index].minImageSize\" \"\$MANIFEST\")\")\"" vm_setup_sh_text)
        && (lib.hasInfix "validate_qcow2_image \"\$_bai_system_img\" \"Android system image for \$_bai_vm_id\"" vm_setup_sh_text)
        && (lib.hasInfix "validate_qcow2_image \"\$_bai_userdata_img\" \"Android userdata disk for \$_bai_vm_id\"" vm_setup_sh_text)
        && (lib.hasInfix "Test-Qcow2Image -ImagePath \$systemImage -ImageLabel \"system image '\$(\$vm.type)'\" -MinBytes \$minSizeBytes" windows_vm_setup_ps1_text)
      )
      "Image validation floors must be parsed from manifest minImageSize instead of hardcoded byte constants";

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

  # id must be present, non-empty, and filesystem-safe (used in file paths,
  # UUID/MAC derivation, and CLI selection).
  test_vm_id_nonempty_and_filesystem_safe =
    let
      badIds = builtins.filter (
        vm:
        !(builtins.hasAttr "id" vm)
        || !builtins.isString vm.id
        || vm.id == ""
        || builtins.match "^[A-Za-z0-9][A-Za-z0-9._-]*$" vm.id == null
      ) manifest.VMs;
    in
    assert' (badIds == [ ])
      "Every VM must have a non-empty filesystem-safe id ([A-Za-z0-9][A-Za-z0-9._-]*); bad entries: ${
        builtins.toString (builtins.map (v: v.name) badIds)
      }";

  # id values must be unique across all VMs.
  test_vm_id_uniqueness =
    let
      ids = builtins.map (vm: vm.id) manifest.VMs;
    in
    assert' (
      builtins.length ids == builtins.length (lib.unique ids)
    ) "All VMs must have distinct id values";

  # portForwards must be a non-empty array of {guestPort, hostPort} objects
  # with integer ports >= 1; every VM exposes at least one forwarded port.
  test_port_forwards_shape =
    let
      badPorts = builtins.filter (
        vm:
        !(builtins.hasAttr "portForwards" vm)
        || !builtins.isList vm.portForwards
        || builtins.length vm.portForwards == 0
        || !builtins.all (
          pf:
          builtins.isAttrs pf
          && (pf ? guestPort)
          && builtins.isInt pf.guestPort
          && pf.guestPort >= 1
          && (pf ? hostPort)
          && builtins.isInt pf.hostPort
          && pf.hostPort >= 1
        ) vm.portForwards
      ) manifest.VMs;
    in
    assert' (badPorts == [ ])
      "Every VM must declare portForwards (non-empty array of {guestPort, hostPort} with integer ports >= 1); bad entries: ${
        builtins.toString (builtins.map (v: v.name) badPorts)
      }";

  # Every hostPort must live in the nucleus VM forward block (22000-22099).
  test_port_forwards_host_range =
    let
      allHostPorts = builtins.concatLists (
        builtins.map (vm: builtins.map (pf: pf.hostPort) vm.portForwards) manifest.VMs
      );
      badHostPorts = builtins.filter (p: p < 22000 || p > 22099) allHostPorts;
    in
    assert' (badHostPorts == [ ])
      "Every portForwards hostPort must be in 22000-22099; bad values: ${builtins.toString badHostPorts}";

  # hostPort values must be globally unique across all VMs.
  test_port_forwards_host_unique =
    let
      allHostPorts = builtins.concatLists (
        builtins.map (vm: builtins.map (pf: pf.hostPort) vm.portForwards) manifest.VMs
      );
    in
    assert' (builtins.length allHostPorts == builtins.length (lib.unique allHostPorts))
      "Every portForwards hostPort must be globally unique; duplicates: ${builtins.toString allHostPorts}";

  # Guest-port semantics: SSH VMs expose guest 22 only; Android exposes 5555+5554, not 22.
  test_port_forwards_guest_semantics =
    let
      badSshVms = builtins.filter (
        vm:
        vm.type != "Android"
        && (builtins.length (builtins.filter (pf: pf.guestPort == 22) vm.portForwards) != 1)
      ) manifest.VMs;
      badAndroidVms = builtins.filter (
        vm:
        vm.type == "Android"
        && (
          builtins.any (pf: pf.guestPort == 22) vm.portForwards
          || builtins.length (builtins.filter (pf: pf.guestPort == 5555) vm.portForwards) != 1
          || builtins.length (builtins.filter (pf: pf.guestPort == 5554) vm.portForwards) != 1
        )
      ) manifest.VMs;
    in
    assert' (badSshVms == [ ] && badAndroidVms == [ ])
      "Non-Android VMs must have exactly one guestPort-22 entry; Android must have guestPort 5555 and 5554 and no guestPort 22; bad SSH VMs: ${
        builtins.toString (builtins.map (v: v.name) badSshVms)
      }; bad Android VMs: ${builtins.toString (builtins.map (v: v.name) badAndroidVms)}";

  # hostname must be a non-empty string (guest OS identity).
  test_hostname_nonempty =
    let
      badHostnames = builtins.filter (
        vm: !(builtins.hasAttr "hostname" vm) || !builtins.isString vm.hostname || vm.hostname == ""
      ) manifest.VMs;
    in
    assert' (badHostnames == [ ])
      "Every VM must declare a non-empty string hostname; bad entries: ${
        builtins.toString (builtins.map (v: v.name) badHostnames)
      }";

  # minImageSize must match the suffixed-size grammar (decimal kB/MB/GB/TB or
  # binary kiB/MiB/GiB/TiB; case-sensitive — KB/KiB are invalid).
  test_min_image_size_pattern =
    let
      badSizes = builtins.filter (
        vm:
        !(builtins.hasAttr "minImageSize" vm)
        || builtins.match "^[0-9]+ ?(kB|MB|GB|TB|kiB|MiB|GiB|TiB)$" vm.minImageSize == null
      ) manifest.VMs;
    in
    assert' (badSizes == [ ])
      "Every VM must declare minImageSize matching ^[0-9]+ ?(kB|MB|GB|TB|kiB|MiB|GiB|TiB)$; bad entries: ${
        builtins.toString (builtins.map (v: v.name) badSizes)
      }";

  # macAddressPrefix must be a non-empty string (MAC address derivation).
  test_mac_address_prefix_nonempty =
    let
      badPrefixes = builtins.filter (
        vm:
        !(builtins.hasAttr "macAddressPrefix" vm)
        || !builtins.isString vm.macAddressPrefix
        || vm.macAddressPrefix == ""
      ) manifest.VMs;
    in
    assert' (badPrefixes == [ ])
      "Every VM must declare a non-empty macAddressPrefix; bad entries: ${
        builtins.toString (builtins.map (v: v.name) badPrefixes)
      }";

  # The UTM MAC must derive its prefix from the manifest's macAddressPrefix
  # field — no hard-coded 52: default in the generator.
  test_macbook_mac_address_uses_manifest_prefix = assert' (
    lib.hasInfix "mkMacAddress vm.id vm.macAddressPrefix" macbook_vms_nix_text
    && !(lib.hasInfix "\"52:\"" macbook_vms_nix_text)
  ) "src/hosts/MacBook/vms.nix must consume vm.macAddressPrefix and not hard-code 52:";

  # Type-specific group objects: a VM carries the group named by its type
  # (Android/macOS/Windows) and no other; NixOS/Linux carry no group.
  groupTypes = [
    "Android"
    "macOS"
    "Windows"
  ];
  test_group_key_equals_type =
    let
      badGroups = builtins.filter (
        vm:
        let
          expected = lib.optional (builtins.elem vm.type groupTypes) vm.type;
          actual = builtins.filter (g: builtins.hasAttr g vm) groupTypes;
        in
        actual != expected
      ) manifest.VMs;
    in
    assert' (badGroups == [ ])
      "Each VM must declare exactly the group object matching its type (Android/macOS/Windows; NixOS/Linux have none); bad entries: ${
        builtins.toString (builtins.map (v: v.name) badGroups)
      }";

  # Every present group object must carry all its required inner properties.
  test_group_inner_props_required =
    let
      androidRequired = [
        "gappsUrl"
        "gsiImage"
        "gsiUrl"
        "magiskUrl"
        "systemImage"
        "userdataImage"
      ];
      checkGroup =
        vm:
        if vm ? Android then
          assert' (builtins.all (p: builtins.hasAttr p vm.Android)
            androidRequired
          ) "Android group for VM '${vm.name}' must declare ${builtins.toString androidRequired}"
        else if vm ? macOS then
          assert' (builtins.hasAttr "version" vm.macOS) "macOS group for VM '${vm.name}' must declare version"
        else if vm ? Windows then
          assert' (
            builtins.hasAttr "edition" vm.Windows && builtins.hasAttr "isoUrl" vm.Windows
          ) "Windows group for VM '${vm.name}' must declare edition and isoUrl"
        else
          null;
      results = builtins.map checkGroup manifest.VMs;
    in
    assert' (builtins.all (r: r == null) results) "Group inner property check failed";

  # Windows VMs must declare a Windows group with isoUrl (string or null; null
  # means auto-resolve via Mido/Fido. Android.gsiUrl may also be null (Lineage-only).
  test_windows_iso_url_type =
    let
      windowsVms = builtins.filter (vm: vm.type == "Windows") manifest.VMs;
      badIsoUrls = builtins.filter (
        vm:
        !(vm ? Windows)
        || !builtins.hasAttr "isoUrl" vm.Windows
        || !(builtins.isString vm.Windows.isoUrl || builtins.isNull vm.Windows.isoUrl)
      ) windowsVms;
    in
    assert' (badIsoUrls == [ ])
      "Windows VMs must declare a Windows group with isoUrl (string or null); bad entries: ${
        builtins.toString (builtins.map (v: v.name) badIsoUrls)
      }";

  # macOS VMs must declare a macOS group with a string version.
  test_macos_version_type =
    let
      macosVms = builtins.filter (vm: vm.type == "macOS") manifest.VMs;
      badVersions = builtins.filter (
        vm: !(vm ? macOS) || !builtins.hasAttr "version" vm.macOS || !builtins.isString vm.macOS.version
      ) macosVms;
    in
    assert' (badVersions == [ ])
      "macOS VMs must declare a macOS group with string version; bad entries: ${
        builtins.toString (builtins.map (v: v.name) badVersions)
      }";

  # Windows VMs must declare a Windows group with a string edition.
  test_windows_edition_type =
    let
      windowsVms = builtins.filter (vm: vm.type == "Windows") manifest.VMs;
      badEditions = builtins.filter (
        vm:
        !(vm ? Windows) || !builtins.hasAttr "edition" vm.Windows || !builtins.isString vm.Windows.edition
      ) windowsVms;
    in
    assert' (badEditions == [ ])
      "Windows VMs must declare a Windows group with string edition; bad entries: ${
        builtins.toString (builtins.map (v: v.name) badEditions)
      }";

  # Android VMs must declare gsiUrl (string or null), gappsUrl, and magiskUrl strings.
  test_android_gsi_url_type =
    let
      androidVms = builtins.filter (vm: vm.type == "Android") manifest.VMs;
      badGsiUrls = builtins.filter (
        vm:
        !(vm ? Android)
        || !builtins.hasAttr "gsiUrl" vm.Android
        || !(builtins.isString vm.Android.gsiUrl || vm.Android.gsiUrl == null)
      ) androidVms;
      badGappsUrls = builtins.filter (
        vm:
        !(vm ? Android)
        || !builtins.hasAttr "gappsUrl" vm.Android
        || !builtins.isString vm.Android.gappsUrl
        || vm.Android.gappsUrl == ""
      ) androidVms;
      badMagiskUrls = builtins.filter (
        vm:
        !(vm ? Android)
        || !builtins.hasAttr "magiskUrl" vm.Android
        || !builtins.isString vm.Android.magiskUrl
        || vm.Android.magiskUrl == ""
      ) androidVms;
    in
    builtins.seq
      (assert' (badGsiUrls == [ ])
        "Android VMs must declare gsiUrl as string or null; bad entries: ${
          builtins.toString (builtins.map (v: v.name) badGsiUrls)
        }"
      )
      (
        builtins.seq
          (assert' (badGappsUrls == [ ])
            "Android VMs must declare a non-empty string gappsUrl; bad entries: ${
              builtins.toString (builtins.map (v: v.name) badGappsUrls)
            }"
          )
          (
            assert' (badMagiskUrls == [ ])
              "Android VMs must declare a non-empty string magiskUrl; bad entries: ${
                builtins.toString (builtins.map (v: v.name) badMagiskUrls)
              }"
          )
      );

  # The Android group must only appear on VMs with type Android.
  test_android_gsi_url_only_on_android =
    let
      badGsiUrlVms = builtins.filter (vm: (vm ? Android) && vm.type != "Android") manifest.VMs;
    in
    assert' (badGsiUrlVms == [ ])
      "The Android group must only appear on VMs of type Android; bad entries: ${
        builtins.toString (builtins.map (v: v.name) badGsiUrlVms)
      }";

  # Android must disable guest audio (sound == "none"): UTM's SPICE audio
  # pipeline teardown deadlocks against the CoreAudio IO thread, freezing the
  # display (see .agents/instructions/vm-management.instructions.md).
  test_android_sound_disabled =
    let
      androidVms = builtins.filter (vm: vm.type == "Android") manifest.VMs;
    in
    assert' (
      builtins.length androidVms == 1 && (builtins.head androidVms).sound == "none"
    ) "VMs.json Android entry must declare sound == \"none\" (UTM SPICE audio deadlock workaround)";

  # hosts must be present and a non-empty array of valid host names
  # (["MacBook", "NixOS", "Windows"]) on every VM; the null "all hosts"
  # shorthand is not allowed — each VM lists the hosts it provisions on.
  validHosts = [
    "MacBook"
    "NixOS"
    "Windows"
  ];
  test_hosts_field =
    let
      badHosts = builtins.filter (
        vm:
        !(builtins.hasAttr "hosts" vm)
        || !builtins.isList vm.hosts
        || builtins.length vm.hosts == 0
        || !builtins.all (host: builtins.elem host validHosts) vm.hosts
      ) manifest.VMs;
    in
    assert' (badHosts == [ ])
      "hosts must be a non-empty list of valid host names (MacBook, NixOS, Windows) on every VM; bad entries: ${
        builtins.toString (builtins.map (v: "${v.name}: ${builtins.toString (v.hosts or null)}") badHosts)
      }";

  # ---------------------------------------------------------------------------
  # Declarative config generation tests
  # ---------------------------------------------------------------------------

  # Deterministic identity derivation, imported from the shared library.
  # UUIDs/MACs are pure SHA-256 functions of the VM id (runtime truth in
  # src/hosts/MacBook/vms.nix); the Windows Pester twin
  # (tests/platforms/Windows/modules/system/vm-disk-model-parity.Tests.ps1) is pinned to the same vectors.
  mkUuid = vmIdentity.mkUuid;

  # UUID must be 36 characters long (8-4-4-4-12 hex with dashes).
  test_plist_uuid_format =
    let
      checkUuid =
        vm:
        assert' (builtins.stringLength (mkUuid vm.id) == 36)
          "UUID for VM '${vm.id}' must be 36 characters; got ${toString (builtins.stringLength (mkUuid vm.id))}";
      results = builtins.map checkUuid manifest.VMs;
    in
    # Force evaluation of all results.
    assert' (builtins.all (r: r == null) results) "UUID format check failed";

  # Each VM must have a distinct UUID so UTM and libvirt can tell them apart.
  test_plist_uuid_uniqueness =
    let
      uuids = builtins.map (vm: mkUuid vm.id) manifest.VMs;
      uniqueUuids = lib.unique uuids;
    in
    assert' (builtins.length uuids == builtins.length uniqueUuids) "All VMs must have distinct UUIDs";

  # Known SHA-256 identity vectors (see src/modules/lib/vm-identity.nix). The
  # vectors pin the derivation so neither the Nix lib nor its shell twin can
  # drift silently; a guest id change is a breaking identity change.
  knownUuidVectors = [
    {
      id = "Android";
      uuid = "6d612a86-bee4-b0a6-59b8-b3affd6f1fbc";
    }
    {
      id = "MacBook";
      uuid = "ac92e761-3044-a456-82e8-cf01eb2471d0";
    }
    {
      id = "NixOS";
      uuid = "cdf51633-aff8-ffbd-4feb-c43ff4de3f1c";
    }
    {
      id = "Windows";
      uuid = "d598026a-9cbc-6050-5f13-8ce53ac78088";
    }
  ];
  knownMacVectors = [
    {
      id = "Android";
      prefix = "52";
      mac = "52:dd:a9:e1:f8:66";
    }
    {
      id = "MacBook";
      prefix = "52";
      mac = "52:d2:6b:37:60:34";
    }
  ];

  # UUID derivation must match the pinned SHA-256 vectors.
  test_identity_uuid_vectors =
    let
      check =
        v:
        let
          got = vmIdentity.mkUuid v.id;
        in
        assert' (got == v.uuid) "vmIdentity.mkUuid '${v.id}' must be '${v.uuid}'; got '${got}'";
      results = builtins.map check knownUuidVectors;
    in
    assert' (builtins.all (r: r == null) results) "identity UUID vector check failed";

  # MAC derivation must match the pinned SHA-256 vectors.
  test_identity_mac_vectors =
    let
      check =
        v:
        let
          got = vmIdentity.mkMacAddress v.id v.prefix;
        in
        assert' (
          got == v.mac
        ) "vmIdentity.mkMacAddress '${v.id}' '${v.prefix}' must be '${v.mac}'; got '${got}'";
      results = builtins.map check knownMacVectors;
    in
    assert' (builtins.all (r: r == null) results) "identity MAC vector check failed";

  # The MacBook host must derive identities from the shared library using the
  # VM id (runtime truth) — never a local re-implementation keyed on name.
  test_macbook_identity_from_shared_lib =
    assert'
      (
        lib.hasInfix "vmIdentity = import ../../modules/lib/vm-identity.nix;" macbook_vms_nix_text
        && lib.hasInfix "vmIdentity.mkUuid vm.id" macbook_vms_nix_text
        && lib.hasInfix "vmIdentity.mkMacAddress vm.id vm.macAddressPrefix" macbook_vms_nix_text
      )
      "src/hosts/MacBook/vms.nix must derive identities from src/modules/lib/vm-identity.nix with vm.id";

  # Domain XML template function (re-implemented without pkgs for test isolation;
  # uses hardcoded x86_64 arch and a placeholder emulator path).
  mkDomainXml =
    vm:
    let
      homeDir = "/home/testuser";
      vmDir = "${homeDir}/virtual machines";
    in
    "<domain type='kvm'>"
    + "\n  <name>${vm.id}</name>"
    + "\n  <memory unit='B'>${toString (size.parse vm.ram)}</memory>"
    + "\n  <vcpu>${toString vm.cpus}</vcpu>"
    + "\n  <devices>"
    + "\n    <source file='${vmDir}/data/${vm.id}.qcow2'/>"
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

  # Domain XML must use unit='B' (exact bytes) so the parsed manifest RAM maps
  # to libvirt without lossy conversion; libvirt's virScaleInteger accepts 'B'.
  # See https://libvirt.org/formatdomain.html
  test_domain_xml_memory_unit =
    let
      results = builtins.map (
        vm:
        assert' (lib.hasInfix "unit='B'>${toString (size.parse vm.ram)}</memory>" (mkDomainXml vm)) "Domain XML for VM '${vm.name}' must specify memory unit='B' with the exact parsed RAM bytes"
      ) manifest.VMs;
    in
    assert' (builtins.all (r: r == null) results) "Domain XML memory unit check failed";

  # Domain XML disk path must use the lowercase 'virtual machines' path.
  test_domain_xml_disk_path_lowercase =
    let
      results = builtins.map (
        vm:
        assert' (lib.hasInfix "virtual machines/data/${vm.id}.qcow2" (mkDomainXml vm)) "Domain XML for VM '${vm.id}' must use lowercase 'virtual machines' in disk path"
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
          cond = builtins.pathExists ../../src/vms/NixOS/base-guest.nix;
          msg = "src/vms/NixOS/base-guest.nix must exist for nixos-generators type builds";
        }
        {
          cond = builtins.pathExists ../../src/vms/guests/NixOS/guest.nix;
          msg = "src/vms/guests/NixOS/guest.nix must exist for per-VM guest identity";
        }
        {
          cond = builtins.pathExists ../../src/vms/NixOS/packer.pkr.hcl;
          msg = "src/vms/NixOS/packer.pkr.hcl must exist for Windows-host NixOS builds";
        }
        {
          cond = builtins.pathExists ../../src/vms/Windows/packer.pkr.hcl;
          msg = "src/vms/Windows/packer.pkr.hcl must exist for Windows 11 builds";
        }
        {
          cond = builtins.pathExists ../../src/vms/Windows/Autounattend.xml;
          msg = "src/vms/Windows/Autounattend.xml must exist for Windows 11 Packer builds";
        }
        {
          cond = builtins.pathExists ../../src/vms/macOS/packer.pkr.hcl;
          msg = "src/vms/macOS/packer.pkr.hcl must exist for macOS Tart builds";
        }
        {
          cond = builtins.pathExists ../../src/vms/NixOS/formats/qcow-btrfs.nix;
          msg = "src/vms/NixOS/formats/qcow-btrfs.nix must exist for x86_64 NixOS guest builds";
        }
        {
          cond = builtins.pathExists ../../src/vms/NixOS/formats/qcow-efi-btrfs.nix;
          msg = "src/vms/NixOS/formats/qcow-efi-btrfs.nix must exist for aarch64 NixOS guest builds";
        }
        {
          cond = builtins.pathExists ../../src/vms/NixOS/disk-image/make-btrfs-disk-image.nix;
          msg = "src/vms/NixOS/disk-image/make-btrfs-disk-image.nix must exist for Btrfs guest images";
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

  test_vm_sync_subcommand_wired = assert' (
    (lib.hasInfix "setup|sync|list" vm_setup_sh_text)
    && (lib.hasInfix "do_sync()" vm_setup_sh_text)
    && (lib.hasInfix "vm_sync_config_phase" vm_setup_sh_text)
    && (lib.hasInfix "'sync'" vm_ps1_text)
    && (lib.hasInfix "function Invoke-VMSync" windows_vm_setup_ps1_text)
  ) "nucleus-vm sync must be wired on POSIX and Windows";

  test_vm_android_config_subcommand_wired = assert' (
    (lib.hasInfix "android-config" vm_setup_sh_text)
    && (lib.hasInfix "do_android_config" vm_setup_sh_text)
    && (lib.hasInfix "android-config) do_android_config" vm_setup_sh_text)
    && (lib.hasInfix "android-config.sh" vm_setup_sh_text)
    && (lib.hasInfix "'android-config'" vm_ps1_text)
    && (lib.hasInfix "vm_android_adb_host_port" vm_setup_sh_text)
    && (lib.hasInfix "Android.gsiUrl != null" vm_setup_sh_text)
    && (lib.hasInfix "virt_wifi" android_fake_wifi_sh_text)
    && (lib.hasInfix "Android.gappsUrl" android_config_sh_text)
    && (lib.hasInfix "Android.magiskUrl" android_magisk_sh_text)
    && (lib.hasInfix "android-magisk.sh" android_config_sh_text)
    && (lib.hasInfix "vm_android_config_magisk" android_magisk_sh_text)
    && (lib.hasInfix "vm_android_config_root" android_magisk_sh_text)
    && (lib.hasInfix "vm_android_magisk_guest_patch_boot" android_magisk_sh_text)
    && (lib.hasInfix "--magisk" android_config_sh_text)
    && (lib.hasInfix "--root" android_config_sh_text)
    && (lib.hasInfix "vm_android_adb_wait_authorized" vm_setup_sh_text)
    && (lib.hasInfix "vm_android_adb_poll_state" vm_setup_sh_text)
    && (lib.hasInfix "vm_android_adb_wait_sideload" vm_setup_sh_text)
    && (lib.hasInfix "vm_android_jqssun_release_tag_for_asset" vm_setup_sh_text)
    && (lib.hasInfix "vm_android_fastboot_wait" vm_setup_sh_text)
    && (lib.hasInfix "vm_android_config_print_manual" android_config_sh_text)
    && (lib.hasInfix "adb sideload" android_config_sh_text)
  ) "nucleus-vm android-config must be wired with GSI-null guards and fake Wi-Fi support";

  test_android_tools_provisioned_all_hosts =
    assert'
      (
        (lib.hasInfix "pkgs.android-tools" flake_nix_text)
        && (lib.hasInfix "pkgs.android-tools" core_nix_text)
        && (lib.hasInfix "Google.PlatformTools" windows_system_packages_dsc_text)
      )
      "adb/fastboot must be provisioned on POSIX (core.nix + nucleus-vm flake) and Windows (Google.PlatformTools winget)";

  test_vm_setup_calls_sync_phase = assert' (
    (lib.hasInfix "vm_prepare_vm_command" vm_setup_sh_text)
    && (lib.hasInfix "vm_sync_config_phase" vm_setup_sh_text)
    && (lib.hasInfix "vm_build_images" vm_setup_sh_text)
  ) "setup must share vm_prepare + vm_sync_config_phase before image build";

  test_vm_sync_utm_includes_registration = assert' (
    (lib.hasInfix "vm_apply_utm_plist_and_register" vm_setup_sh_text)
    && (lib.hasInfix "re_register_utm_bundle" vm_setup_sh_text)
    && (lib.hasInfix "wait_for_utm_registration" vm_setup_sh_text)
  ) "vm sync must refresh UTM plists and repair registration on drift";

  test_vm_setup_removes_utm_screenshot = assert' (
    (lib.hasInfix "vm_remove_utm_screenshot" vm_setup_sh_text)
    && (lib.hasInfix "screenshot.png" vm_setup_sh_text)
  ) "vm setup/sync must purge stale UTM screenshots from bundles";

  test_apply_vm_sync_default_on = assert' (
    (lib.hasInfix "vm_sync=true" apply_sh_text)
    && (lib.hasInfix "run_vm_post_apply" apply_sh_text)
    && (lib.hasInfix "nucleus-vm sync" apply_sh_text)
    && (lib.hasInfix "Invoke-VMSync" (builtins.readFile ../../src/hosts/Windows/apply.ps1))
  ) "apply must run VM config sync by default with setup as the opt-in heavy path";

  # Every enabled VM must be reachable by at least one known host (MacBook,
  # NixOS, Windows).  An orphaned VM (enabled but with a hosts list that
  # excludes all known hosts) would never be provisioned by any machine.
  # This mirrors the get_expected_vm_ids filter logic used by vm-setup GC.
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
    (lib.hasInfix "vm_get_manifest_vm_ids" vm_setup_sh_text)
    && (lib.hasInfix "if [ \"\$gc_disabled_mode\" = true ]" vm_setup_sh_text)
    && (lib.hasInfix "gc_disabled_mode=false" vm_setup_sh_text)
    && (lib.hasInfix "_gcv_expected=\"\$(vm_get_manifest_vm_ids)\"" vm_setup_sh_text)
  ) "vm-setup GC must preserve disabled VM entries by default and clear them only with --gc-disabled";

  # The --gc-disabled/--no-gc-disabled option pair must be accepted in both
  # parse loops (global and post-subcommand) and documented in usage.
  test_vm_gc_disabled_option_pair = assert' (
    (containsRegex "--gc-disabled[)].*gc_disabled_mode=true.*shift" vm_setup_sh_text)
    && (containsRegex "--no-gc-disabled[)].*gc_disabled_mode=false.*shift" vm_setup_sh_text)
    && (lib.hasInfix "--gc-disabled) gc_disabled_mode=true ;;" vm_setup_sh_text)
    && (lib.hasInfix "--no-gc-disabled) gc_disabled_mode=false ;;" vm_setup_sh_text)
    && (lib.hasInfix "--gc-disabled|--no-gc-disabled" vm_setup_sh_text)
  ) "vm.sh must accept the --gc-disabled/--no-gc-disabled option pair in both parse loops and usage";

  # GC must skip data/ runtime overlays by default; --gc-data opts into sweeping
  # orphaned data/ disks and their sidecar markers.
  test_vm_gc_data_skips_data_by_default = assert' (
    (lib.hasInfix "gc_data_mode=false" vm_setup_sh_text)
    && (lib.hasInfix "if [ \"\$gc_data_mode\" = true ]" vm_setup_sh_text)
    && (lib.hasInfix "SRC_DIR=\"\$VM_DIR/src\"" vm_setup_sh_text)
  ) "vm-setup GC must preserve data/ runtime overlays by default and sweep them only with --gc-data";

  test_vm_gc_data_option_pair = assert' (
    (containsRegex "--gc-data[)].*gc_data_mode=true.*shift" vm_setup_sh_text)
    && (containsRegex "--no-gc-data[)].*gc_data_mode=false.*shift" vm_setup_sh_text)
    && (lib.hasInfix "--gc-data) gc_data_mode=true ;;" vm_setup_sh_text)
    && (lib.hasInfix "--no-gc-data) gc_data_mode=false ;;" vm_setup_sh_text)
    && (lib.hasInfix "--gc-data|--no-gc-data" vm_setup_sh_text)
  ) "vm.sh must accept the --gc-data/--no-gc-data option pair in both parse loops and usage";

  test_windows_vm_gc_data_option_pair = assert' (
    (lib.hasInfix "[switch]\$GcData" windows_vm_setup_ps1_text)
    && (lib.hasInfix "'--gc-data' { \$gcData = \$true }" vm_ps1_text)
    && (lib.hasInfix "'--no-gc-data' { \$gcData = \$false }" vm_ps1_text)
  ) "Windows vm-setup GC must preserve data/ by default and sweep it only with --gc-data/-GcData";

  # Windows vm-setup must mirror POSIX GC: preserve disabled entries by
  # default, clear them only with -GcDisabled (--gc-disabled/--no-gc-disabled).
  test_windows_vm_gc_preserves_disabled_entries_by_default =
    assert'
      (
        (lib.hasInfix "[switch]\$GcDisabled" windows_vm_setup_ps1_text)
        && (lib.hasInfix "\$expectedNames = @(\$vmDef.VMs | ForEach-Object { \$_.id })" windows_vm_setup_ps1_text)
        && (lib.hasInfix "'--gc-disabled' { \$invokeArgs['GcDisabled'] = \$true }" vm_ps1_text)
        && (lib.hasInfix "'--no-gc-disabled' { \$invokeArgs['GcDisabled'] = \$false }" vm_ps1_text)
      )
      "Windows vm-setup GC must preserve disabled VM entries by default and clear them only with --gc-disabled/-GcDisabled";

  # GC keep-sets must preserve every manifest-referenced disk image: type
  # system images, Android system/GSI images under src/<type>/, and data disks
  # under data/ when --gc-data is enabled. Matching by full
  # filename (with extension) keeps canonical artifacts (system image.qcow2,
  # Android system/GSI/userdata images) from being orphaned by a
  # basename-stripped guest-id comparison.
  test_vm_gc_keep_set_preserves_manifest_images = assert' (
    (lib.hasInfix "vm_gc_disk_keep_set" vm_setup_sh_text)
    && (lib.hasInfix ".Android.systemImage" vm_setup_sh_text)
    && (lib.hasInfix ".Android.gsiImage" vm_setup_sh_text)
    && (lib.hasInfix ".Android.userdataImage" vm_setup_sh_text)
    && (lib.hasInfix "_gcod_name=\"\$(basename \"\$_gcod_path\")\"" vm_setup_sh_text)
  ) "vm-setup GC keep-set must preserve manifest-referenced images and match full filenames";

  # Orphaned VM descriptors are removed when their guest leaves the expected
  # set.  Descriptors are keyed to the expected set, not disk existence,
  # because macOS/tart guests keep their disks in tart's store.
  test_vm_gc_orphan_descriptors_removed = assert' (
    (lib.hasInfix "vm_gc_orphan_descriptors" vm_setup_sh_text)
    && (lib.hasInfix "vm_descriptor_path" vm_setup_sh_text)
    && (lib.hasInfix "vm_gc_orphan_descriptors \"\$_gcv_expected\"" vm_setup_sh_text)
  ) "vm-setup GC must remove orphaned VM descriptors for guests absent from the expected set";

  # src/<type>/ type markers gate the type system image AND tart registrations,
  # so they are removed only when the guest leaves the expected set; data/
  # sidecar markers are removed when their disk image is gone (only with --gc-data).
  test_vm_gc_marker_expected_set_semantics =
    assert'
      (
        (lib.hasInfix "vm_gc_orphan_markers" vm_setup_sh_text)
        && (lib.hasInfix "for _gcom_type_dir in \"\$SRC_DIR\"/*/" vm_setup_sh_text)
        && (lib.hasInfix "VM_TYPE_MARKER_BASE}.vm-type-config-sha256" vm_setup_sh_text)
        && (lib.hasInfix "if [ \"\$gc_data_mode\" = true ]" vm_setup_sh_text)
      )
      "vm-setup marker GC must key src/<type>/ type markers to the expected set and sweep data/ markers only with --gc-data";

  # Windows vm-setup must mirror POSIX keep-set semantics: match full disk
  # filenames against per-directory keep-sets and sweep config markers too.
  test_windows_vm_gc_keep_set =
    assert'
      (
        (lib.hasInfix "Get-VMGcSrcKeepSetForType" windows_vm_setup_ps1_text)
        && (lib.hasInfix "Get-VMGcDataDiskKeepSet" windows_vm_setup_ps1_text)
        && (lib.hasInfix "\$disk.Name -notin \$keep" windows_vm_setup_ps1_text)
        && (lib.hasInfix "vm-type-config-sha256" windows_vm_setup_ps1_text)
        && (lib.hasInfix "vm-provision-sha256" windows_vm_setup_ps1_text)
      )
      "Windows vm-setup GC must match full filenames against keep-sets and sweep type-config and provision markers";

  # Commit 5: the fingerprint marker split.  POSIX vm-setup must track the
  # type system image with a type-config marker and each data disk with a
  # per-VM provision marker (identity + wiring + credentials).
  test_vm_fingerprint_marker_split =
    assert'
      (
        (lib.hasInfix "vm_type_config_marker_path() {" vm_setup_sh_text)
        && (lib.hasInfix "vm_type_config_fingerprint() {" vm_setup_sh_text)
        && (lib.hasInfix "vm_type_image_fingerprint() {" vm_setup_sh_text)
        && (lib.hasInfix "vm_provision_marker_path() {" vm_setup_sh_text)
        && (lib.hasInfix "vm_provision_fingerprint() {" vm_setup_sh_text)
        && (lib.hasInfix "VM_TYPE_MARKER_BASE}.vm-type-config-sha256" vm_setup_sh_text)
        && (lib.hasInfix "vm-provision-sha256" vm_setup_sh_text)
        && (lib.hasInfix "_rmi_fingerprint=\"\$3\"" vm_setup_sh_text)
        && (lib.hasInfix "resize_and_mark_image IMAGE_PATH MARKER_PATH FINGERPRINT [DISK_BYTES]" vm_setup_sh_text)
      )
      "vm-setup must split markers into a type-config marker for the type image and a per-VM provision marker for each data disk";

  # Windows vm-setup must mirror the fingerprint marker split with matching
  # helper names and marker suffixes.
  test_windows_vm_fingerprint_marker_split =
    assert'
      (
        (lib.hasInfix "function Get-VMTypeConfigHash" windows_vm_setup_ps1_text)
        && (lib.hasInfix "function Get-VMTypeImageHash" windows_vm_setup_ps1_text)
        && (lib.hasInfix "function Get-VMProvisionHash" windows_vm_setup_ps1_text)
        && (lib.hasInfix "function Get-VMTypeConfigMarkerPath" windows_vm_setup_ps1_text)
        && (lib.hasInfix "function Get-VMProvisionMarkerPath" windows_vm_setup_ps1_text)
        && (lib.hasInfix "function Test-VMMarker" windows_vm_setup_ps1_text)
        && (lib.hasInfix "vm-type-config-sha256" windows_vm_setup_ps1_text)
        && (lib.hasInfix "vm-provision-sha256" windows_vm_setup_ps1_text)
      )
      "Windows vm-setup must split markers into type-config and per-VM provision markers with matching helper names";

  # base-guest.nix and guests/<id>/guest.nix must be non-empty (parseable as
  # Nix expressions).
  test_guest_nix_nonempty =
    let
      baseContent = builtins.readFile ../../src/vms/NixOS/base-guest.nix;
      guestContent = builtins.readFile ../../src/vms/guests/NixOS/guest.nix;
    in
    assert' (
      builtins.stringLength baseContent > 0 && builtins.stringLength guestContent > 0
    ) "src/vms/NixOS/base-guest.nix and src/vms/guests/NixOS/guest.nix must not be empty";

  # The NixOS guest image must not force virtio_fs into the initrd. The share
  # is optional at runtime and some current kernels do not provide a loadable
  # virtio_fs module, which would make image generation fail before first boot.
  base_guest_nix_text = builtins.readFile ../../src/vms/NixOS/base-guest.nix;
  guest_vm_nix_text = builtins.readFile ../../src/vms/guests/NixOS/guest.nix;
  core_nix_text = builtins.readFile ../../src/modules/core.nix;
  nixos_packer_text = builtins.readFile ../../src/vms/NixOS/packer.pkr.hcl;
  nixos_disks_nix_text = builtins.readFile ../../src/hosts/NixOS/hardware/disks.nix;
  btrfs_options_nix_text = builtins.readFile ../../src/hosts/NixOS/btrfs-options.nix;
  qcow_btrfs_text = builtins.readFile ../../src/vms/NixOS/formats/qcow-btrfs.nix;
  qcow_efi_btrfs_text = builtins.readFile ../../src/vms/NixOS/formats/qcow-efi-btrfs.nix;
  btrfs_patch_text = builtins.readFile ../../src/vms/NixOS/disk-image/make-disk-image-btrfs.patch;
  # NixOS guest must enable the QEMU guest agent for host-guest communication
  # (VM lifecycle events, ballooning, clipboard sharing, etc.)
  test_nixos_guest_qemu_guest_enabled = assert' (lib.hasInfix "services.qemuGuest.enable = true;" base_guest_nix_text) "NixOS base-guest.nix must enable services.qemuGuest.enable";

  # NixOS guest must enable OpenSSH for remote access and credential-free
  # host-guest communication via the QEMU SSH port forward.
  test_nixos_guest_openssh_enabled = assert' (lib.hasInfix "services.openssh.enable = true;" base_guest_nix_text) "NixOS base-guest.nix must enable services.openssh.enable";

  # NixOS guest must declare the nucleus-rebuild oneshot systemd service for
  # converging the guest to the latest flake-defined state.
  test_nixos_guest_nucleus_rebuild_service = assert' (lib.hasInfix "systemd.services.nucleus-rebuild" base_guest_nix_text) "NixOS base-guest.nix must declare the nucleus-rebuild systemd service";

  # NixOS guest must accept the SSH public key via the
  # NUCLEUS_VM_GUEST_SSH_PUBLIC_KEY environment variable so the host can
  # authenticate to the guest without interactive password entry.
  test_nixos_guest_ssh_authorized_keys = assert' (lib.hasInfix "NUCLEUS_VM_GUEST_SSH_PUBLIC_KEY" guest_vm_nix_text) "src/vms/guests/NixOS/guest.nix must reference NUCLEUS_VM_GUEST_SSH_PUBLIC_KEY in authorized keys";

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
  apply_sh_text = builtins.readFile ../../src/scripts/apply.sh;
  windows_vm_setup_ps1_text = builtins.readFile ../../src/platforms/Windows/modules/system/Invoke-VMSetup.ps1;
  readmeTemplateText = builtins.readFile ../../src/vms/templates/README.md;
  startPosixTemplateText = builtins.readFile ../../src/vms/templates/start-posix.sh;
  startWindowsTemplateText = builtins.readFile ../../src/vms/templates/start-windows.ps1;
  startWindowsHostTemplateText = builtins.readFile ../../src/vms/templates/start-windows-host.sh;
  startHostPs1TemplateText = builtins.readFile ../../src/vms/templates/start-host.ps1;
  stopPosixShTemplateText = builtins.readFile ../../src/vms/templates/stop-posix.sh;
  stopHostPs1TemplateText = builtins.readFile ../../src/vms/templates/stop-host.ps1;
  macbook_vms_nix_text = builtins.readFile ../../src/hosts/MacBook/vms.nix;
  nixos_vms_nix_text = builtins.readFile ../../src/hosts/NixOS/vms.nix;
  nixos_domain_xml_text = builtins.readFile ../../src/modules/configs/vms/nixos-domain.xml;
  utmConfigPlistText = builtins.readFile ../../src/modules/configs/vms/utm-config.plist.xml;
  vms_json_text = builtins.readFile ../../src/modules/VMs.json;
  vm_guest_json_text = builtins.readFile ../../src/users/default/vm-guest.json;
  user_secret_text = builtins.readFile ../fixtures/user-registry/src/secrets/users/test-user.yml;
  vms_windows_packer_text = builtins.readFile ../../src/vms/Windows/packer.pkr.hcl;
  vms_windows_autounattend_text = builtins.readFile ../../src/vms/Windows/Autounattend.xml;
  vms_macos_packer_text = builtins.readFile ../../src/vms/macOS/packer.pkr.hcl;
  windows_vm_android_ps1_text = builtins.readFile ../../src/platforms/Windows/modules/system/VMAndroid.ps1;
  start_android_ps1_text = builtins.readFile ../../src/scripts/vms/start-android-vm.ps1;
  android_config_sh_text = builtins.readFile ../../src/scripts/vms/android-config.sh;
  android_fake_wifi_sh_text = builtins.readFile ../../src/scripts/vms/android-fake-wifi.sh;
  android_magisk_sh_text = builtins.readFile ../../src/scripts/vms/android-magisk.sh;
  flake_nix_text = builtins.readFile ../../src/flake.nix;
  windows_system_packages_dsc_text = builtins.readFile ../../src/hosts/Windows/system/packages.dsc.yml;
  guest_ssh_public_key_manifest_text = builtins.readFile ../../src/modules/vm-guest-ssh-public-key-paths.json;

  test_vm_guest_ssh_public_key_manifest = assert' (
    lib.hasInfix "ssh_personal_{username}.pub" guest_ssh_public_key_manifest_text
    && lib.hasInfix "id_ed25519.pub" guest_ssh_public_key_manifest_text
  ) "vm-guest-ssh-public-key-paths.json must list static and username-scoped SSH public key paths";

  test_vm_guest_ssh_public_key_resolver_wired = assert' (
    (lib.hasInfix "vm_resolve_guest_ssh_public_key" vm_setup_sh_text)
    && !(lib.hasInfix "resolve_vm_guest_ssh_key" vm_setup_sh_text)
    && (lib.hasInfix "vm-guest-ssh-public-key-paths.json" vm_setup_sh_text)
    && (lib.hasInfix "Get-VMGuestSshPublicKey" windows_vm_setup_ps1_text)
    && !(lib.hasInfix "function Resolve-VMGuestSshKey" windows_vm_setup_ps1_text)
  ) "POSIX and Windows VM setup must resolve guest SSH keys via the shared manifest";

  # hostname must equal display name (guest OS identity contract).
  test_hostname_equals_name =
    let
      badHostnameName = builtins.filter (vm: vm.hostname != vm.name) manifest.VMs;
    in
    assert' (badHostnameName == [ ])
      "Every VM hostname must equal name; bad entries: ${
        builtins.toString (builtins.map (v: v.name) badHostnameName)
      }";

  test_vm_android_recovery_filename_parity = assert' (
    lib.hasInfix "recovery userdebug.img" vm_setup_sh_text
    && lib.hasInfix "recovery userdebug.tag.json" vm_setup_sh_text
    && lib.hasInfix "recovery userdebug.img" windows_vm_android_ps1_text
    && lib.hasInfix "recovery userdebug.tag.json" windows_vm_android_ps1_text
  ) "POSIX vm.sh and Windows VMAndroid.ps1 must share Android recovery cache filenames";

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

  test_nixos_guest_btrfs_format_paths = assert' (
    (lib.hasInfix "formats/qcow-btrfs.nix" vm_setup_sh_text)
    && (lib.hasInfix "formats/qcow-efi-btrfs.nix" vm_setup_sh_text)
    && (lib.hasInfix "--format-path" vm_setup_sh_text)
    && !(lib.hasInfix "--format qcow\"" vm_setup_sh_text)
  ) "scripts/vm.sh must build NixOS guests with qcow-btrfs / qcow-efi-btrfs format modules";

  test_nixos_host_disks_btrfs_root = assert' (lib.hasInfix ''fsType = "btrfs";'' nixos_disks_nix_text) "src/hosts/NixOS/hardware/disks.nix must declare a Btrfs root filesystem";

  test_nixos_btrfs_subvolume_layout = assert' (
    (lib.hasInfix "compress-force=zstd" btrfs_options_nix_text)
    && (lib.hasInfix "subvol=@nix" btrfs_options_nix_text)
    && (lib.hasInfix "subvol=@" btrfs_options_nix_text)
    && (lib.hasInfix "btrfsOptions.root" nixos_disks_nix_text)
    && (lib.hasInfix "btrfsOptions.nix" nixos_disks_nix_text)
    && (lib.hasInfix ''fileSystems."/nix"'' nixos_disks_nix_text)
    && (lib.hasInfix "btrfs-options.nix" qcow_btrfs_text)
    && (lib.hasInfix "btrfsOptions.root" qcow_btrfs_text)
    && (lib.hasInfix "btrfsOptions.nix" qcow_btrfs_text)
    && (lib.hasInfix ''fileSystems."/nix"'' qcow_btrfs_text)
    && (lib.hasInfix "btrfs-options.nix" qcow_efi_btrfs_text)
    && (lib.hasInfix "btrfsOptions.root" qcow_efi_btrfs_text)
    && (lib.hasInfix "btrfsOptions.nix" qcow_efi_btrfs_text)
    && (lib.hasInfix ''fileSystems."/nix"'' qcow_efi_btrfs_text)
    && (lib.hasInfix "compress-force=zstd" nixos_packer_text)
    && (lib.hasInfix "subvol=@nix" nixos_packer_text)
    && (lib.hasInfix "btrfs subvolume create /mnt/@nix" nixos_packer_text)
    && (lib.hasInfix "btrfs subvolume create" btrfs_patch_text)
    && (lib.hasInfix "rsync -a --exclude=nix/" btrfs_patch_text)
  ) "NixOS host and guest images must use @/@nix btrfs layout with compress-force=zstd";

  test_nixos_guest_documents_btrfs_formats = assert' (
    (lib.hasInfix "qcow-btrfs" base_guest_nix_text)
    && (lib.hasInfix "qcow-efi-btrfs" base_guest_nix_text)
    && !(lib.hasInfix "ext4" base_guest_nix_text)
  ) "src/vms/NixOS/base-guest.nix must document Btrfs qcow format modules instead of ext4";

  test_nixos_packer_btrfs_root = assert' (
    (lib.hasInfix "mkfs.btrfs" nixos_packer_text) && !(lib.hasInfix "mkfs.ext4" nixos_packer_text)
  ) "src/vms/NixOS/packer.pkr.hcl must format the root partition as Btrfs";

  # nixos-generators produces a small default qcow2 unless resized explicitly.
  # vm-setup must resize NixOS images to manifest disk size so provisioning
  # logic does not reject the pre-built image for being too small.
  test_nixos_image_resize_to_manifest_disk = assert' (
    (lib.hasInfix "vm_build_nixos TYPE DISK_BYTES" vm_setup_sh_text)
    && (lib.hasInfix "if ! resize_and_mark_image \"$_out\" \"$_marker\" \"$_type_fp\" \"$_disk_bytes\"; then" vm_setup_sh_text)
  ) "scripts/vm.sh must resize generated NixOS qcow2 images to the exact manifest disk byte count";

  # The runtime resize path must be grow-only: resize_and_mark_image only
  # grows when the current virtual size is below the requested size, and
  # vm_resize_vm refuses to shrink without --allow-shrink (never destroys
  # data by default).  The writable disk is always data/<id>.qcow2 — for
  # Android that disk IS the userdata image, so resizing it resizes the
  # user's data disk.
  test_vm_resize_grow_only_and_guard =
    assert'
      (
        (lib.hasInfix "if [ \"$_rmi_current_size\" -lt \"$_rmi_disk_bytes\" ]; then" vm_setup_sh_text)
        && (lib.hasInfix "vm_resize_vm() {" vm_setup_sh_text)
        && (lib.hasInfix "_rvm_disk=\"$VM_DIR/data/\${_rvm_id}.qcow2\"" vm_setup_sh_text)
        && (lib.hasInfix "shrink requires --allow-shrink" vm_setup_sh_text)
        && (lib.hasInfix "_rvm_qemu_args=(--shrink)" vm_setup_sh_text)
        && (lib.hasInfix "vm_get_running_ids" vm_setup_sh_text)
      )
      "scripts/vm.sh must resize grow-only: resize_and_mark_image never shrinks, vm_resize_vm guards shrink with --allow-shrink, rejects running VMs, and targets data/<id>.qcow2";

  # Running-state detection must distinguish registered catalog entries from
  # actually running VMs on macOS (utmctl Status, tart JSON .Running).

  # The resize subcommand must be wired into the CLI: usage synopsis,
  # dispatch, size parsing via parse_size, and the --allow-shrink flag.
  test_vm_resize_cli_subcommand =
    assert'
      (
        (lib.hasInfix "setup|sync|build-system|list|status|start|stop|upgrade|reset|android-config|inject|gc|resize|pack|unpack [vm...] [options]" vm_setup_sh_text)
        && (lib.hasInfix "resize <vm> <size>" vm_setup_sh_text)
        && (lib.hasInfix "--allow-shrink) allow_shrink=true" vm_setup_sh_text)
        && (lib.hasInfix "do_resize() {" vm_setup_sh_text)
        && (lib.hasInfix "disk_bytes=\"\$(parse_size \"$size_arg\")\" || exit 1" vm_setup_sh_text)
        && (lib.hasInfix "vm_resize_vm \"$vm_id\" \"$disk_bytes\" \"$allow_shrink\"" vm_setup_sh_text)
        && (containsRegex "setup *\\| *sync *\\| *build-system *\\| *list *\\| *status *\\| *start *\\| *stop *\\| *upgrade *\\| *reset *\\| *inject *\\| *gc *\\| *resize *\\| *pack *\\| *unpack[)] \"do_\\$action\" ;;" vm_setup_sh_text)
      )
      "scripts/vm.sh must wire the resize subcommand (usage, dispatch, parse_size, --allow-shrink) to vm_resize_vm";

  # The Windows twin must mirror the resize subcommand: ValidateSet, dispatch,
  # Invoke-VMResize with --allow-shrink, and ConvertFrom-SizeString parsing.
  test_vm_resize_windows_twin =
    assert'
      (
        (lib.hasInfix "reset', 'android-config', 'inject', 'resize', 'gc', 'pack', 'unpack'" vm_ps1_text)
        && (lib.hasInfix "'resize'  { Invoke-VMResize }" vm_ps1_text)
        && (lib.hasInfix "function Invoke-VMResize {" vm_ps1_text)
        && (lib.hasInfix "'--allow-shrink' { $allowShrink = $true }" vm_ps1_text)
        && (lib.hasInfix "ConvertFrom-SizeString $sizeArg" vm_ps1_text)
      )
      "scripts/vm.ps1 must mirror the resize subcommand (ValidateSet, dispatch, Invoke-VMResize, --allow-shrink)";

  # The pack subcommand must be wired into the CLI: usage synopsis, dispatch,
  # do_pack with dry-run-by-default (--force performs), the running-VM refusal,
  # and vm_pack_vms.
  test_vm_pack_cli_subcommand =
    assert'
      (
        (lib.hasInfix "setup|sync|build-system|list|status|start|stop|upgrade|reset|android-config|inject|gc|resize|pack|unpack [vm...] [options]" vm_setup_sh_text)
        && (lib.hasInfix "pack                     Strip trivially regenerable artifacts" vm_setup_sh_text)
        && (containsRegex "setup *\\| *sync *\\| *build-system *\\| *list *\\| *status *\\| *start *\\| *stop *\\| *upgrade *\\| *reset *\\| *inject *\\| *gc *\\| *resize *\\| *pack *\\| *unpack[)] \"do_\\$action\" ;;" vm_setup_sh_text)
        && (lib.hasInfix "do_pack() {" vm_setup_sh_text)
        && (lib.hasInfix "if [ \"$force\" != true ]; then" vm_setup_sh_text)
        && (lib.hasInfix "vm_pack_vms" vm_setup_sh_text)
      )
      "scripts/vm.sh must wire the pack subcommand (usage, dispatch, do_pack with dry-run-by-default, vm_pack_vms)";

  # pack's keep-set must exactly match the trivially-regenerable rule: only
  # UTM bundles, generated start/stop scripts, and src/<type>/Packer/ + stale
  # dot-dirs are removed; everything else (src/, data/, descriptors) stays.
  test_vm_pack_removal_set =
    assert'
      (
        (lib.hasInfix "removing regenerable UTM bundle" vm_setup_sh_text)
        && (lib.hasInfix "\"$VM_DIR\"/*.utm/; do" vm_setup_sh_text)
        && (lib.hasInfix "removing regenerable start/stop script" vm_setup_sh_text)
        && (lib.hasInfix "scripts/start-*.sh" vm_setup_sh_text)
        && (lib.hasInfix "scripts/stop-*.ps1" vm_setup_sh_text)
        && (lib.hasInfix "removing transient Packer directory" vm_setup_sh_text)
        && (lib.hasInfix "$VM_PACKER_BUILD_DIR" vm_setup_sh_text)
        && (lib.hasInfix "cannot pack while a VM is running" vm_setup_sh_text)
      )
      "vm_pack_vms must remove only trivially regenerable artifacts (UTM bundles, start/stop scripts, Packer/ + dot-dirs) and refuse while a VM is running";

  # pack must refuse while any VM is running and print next steps.
  test_vm_pack_next_steps = assert' (
    (lib.hasInfix "copy the packed tree to the target host" vm_setup_sh_text)
    && (lib.hasInfix "nucleus-vm unpack' or 'nucleus-vm setup'" vm_setup_sh_text)
  ) "vm_pack_vms must print next steps (nucleus-vm unpack or nucleus-vm setup on the target)";

  # The Windows twin must mirror the pack subcommand: ValidateSet, dispatch,
  # Invoke-VMPack with dry-run-by-default (--force performs), and running-VM refusal.
  test_vm_pack_windows_twin =
    assert'
      (
        (lib.hasInfix "'gc', 'pack', 'unpack'" vm_ps1_text)
        && (lib.hasInfix "'pack'    { Invoke-VMPack }" vm_ps1_text)
        && (lib.hasInfix "function Invoke-VMPack {" vm_ps1_text)
        && (lib.hasInfix "'--force' { $perform = $true }" vm_ps1_text)
        && (lib.hasInfix "cannot pack while a VM is running" vm_ps1_text)
      )
      "scripts/vm.ps1 must mirror the pack subcommand (ValidateSet, dispatch, Invoke-VMPack with --force)";

  # The unpack subcommand must be wired into the CLI: usage synopsis + body,
  # dispatch, do_unpack, and vm_unpack_vms regenerating from descriptors
  # (BOTH start/stop variants, enabled or disabled) plus the wrappers.
  test_vm_unpack_cli_subcommand =
    assert'
      (
        (lib.hasInfix "unpack                   Regenerate per-platform VM artifacts" vm_setup_sh_text)
        && (containsRegex "setup *\\| *sync *\\| *build-system *\\| *list *\\| *status *\\| *start *\\| *stop *\\| *upgrade *\\| *reset *\\| *inject *\\| *gc *\\| *resize *\\| *pack *\\| *unpack[)] \"do_\\$action\" ;;" vm_setup_sh_text)
        && (lib.hasInfix "do_unpack() {" vm_setup_sh_text)
        && (lib.hasInfix "vm_unpack_vms() {" vm_setup_sh_text)
        && (lib.hasInfix "\"$VM_DIR\"/*.vm.json" vm_setup_sh_text)
        && (lib.hasInfix "vm_write_start_script \"$(cat \"$_uv_desc\")\" \"$_uv_host_kind\"" vm_setup_sh_text)
        && (lib.hasInfix "vm_write_stop_script \"$(cat \"$_uv_desc\")\" \"$_uv_host_kind\"" vm_setup_sh_text)
        && (lib.hasInfix "vm_write_pack_unpack_scripts" vm_setup_sh_text)
      )
      "scripts/vm.sh must wire the unpack subcommand (usage, dispatch, do_unpack, vm_unpack_vms over descriptors)";

  # unpack must gate bundle/domain creation on enabled descriptors (mirrors
  # setup) and consume copied data files as-is.
  test_vm_unpack_enabled_gate =
    assert'
      (
        (lib.hasInfix "if [ \"$_uv_enabled\" != \"true\" ]; then" vm_setup_sh_text)
        && (lib.hasInfix "descriptor '$_uv_name' is disabled; scripts rendered, no bundle/domain" vm_setup_sh_text)
        && (lib.hasInfix "data files are consumed" vm_setup_sh_text)
      )
      "vm_unpack_vms must gate bundle/domain creation on enabled descriptors and consume data files as-is";

  # vm_vm_json must prefer the on-disk descriptor and fall back to the
  # manifest entry so rendering works on a fresh tree (setup-side) and from
  # descriptors on a packed tree (unpack-side).
  test_vm_unpack_descriptor_first = assert' (
    (lib.hasInfix "vm_vm_json() {" vm_setup_sh_text)
    && (lib.hasInfix "vm_descriptor_path" vm_setup_sh_text)
    && (lib.hasInfix ".VMs[] | select(.id == $n)" vm_setup_sh_text)
  ) "vm.sh must provide vm_vm_json with descriptor-first, manifest-fallback JSON for VM rendering";

  # The Windows twin must mirror the unpack subcommand: ValidateSet, dispatch,
  # Invoke-VMUnpack with --dry-run support.
  test_vm_unpack_windows_twin =
    assert'
      (
        (lib.hasInfix "'gc', 'pack', 'unpack'" vm_ps1_text)
        && (lib.hasInfix "'unpack'  { Invoke-VMUnpack }" vm_ps1_text)
        && (lib.hasInfix "function Invoke-VMUnpack {" vm_ps1_text)
        && (lib.hasInfix "'--dry-run' { $perform = $false }" vm_ps1_text)
      )
      "scripts/vm.ps1 must mirror the unpack subcommand (ValidateSet, dispatch, Invoke-VMUnpack with --dry-run)";

  # The build-system subcommand must be wired into the CLI: usage synopsis +
  # body, dispatch, do_build_system validating the type against the manifest,
  # and vm_build_system doing the type-scoped system image build.
  test_vm_build_system_cli_subcommand =
    assert'
      (
        (lib.hasInfix "setup|sync|build-system|list|status|start|stop|upgrade|reset|android-config|inject|gc|resize|pack|unpack [vm...] [options]" vm_setup_sh_text)
        && (lib.hasInfix "build-system <type>      Build/rebuild the type-scoped system image (src/<type>/system image.qcow2)." vm_setup_sh_text)
        && (containsRegex "setup *\\| *sync *\\| *build-system *\\| *list" vm_setup_sh_text)
        && (lib.hasInfix "do_build_system() {" vm_setup_sh_text)
        && (lib.hasInfix "build-system requires a VM type" vm_setup_sh_text)
        && (lib.hasInfix "vm_build_system \"$vm_type\"" vm_setup_sh_text)
      )
      "scripts/vm.sh must wire the build-system subcommand (usage, dispatch, do_build_system with manifest validation, vm_build_system)";

  # The Windows twin must mirror the build-system subcommand: ValidateSet,
  # dispatch, Invoke-VMBuildSystem wrapper, and Invoke-VMSystemBuild delegate.
  test_vm_build_system_windows_twin =
    assert'
      (
        (lib.hasInfix "'sync', 'build-system', 'list'" vm_ps1_text)
        && (lib.hasInfix "'build-system' { Invoke-VMBuildSystem }" vm_ps1_text)
        && (lib.hasInfix "function Invoke-VMBuildSystem {" vm_ps1_text)
        && (lib.hasInfix "Invoke-VMSystemBuild" vm_ps1_text)
      )
      "scripts/vm.ps1 must mirror the build-system subcommand (ValidateSet, dispatch, Invoke-VMBuildSystem wrapper, Invoke-VMSystemBuild delegate)";

  # The inject subcommand must be wired into the CLI: usage synopsis + body,
  # dispatch, do_inject validating the VM id against the manifest, and
  # vm_inject_guest doing the per-VM in-place disk injection.
  test_vm_inject_cli_subcommand =
    assert'
      (
        (lib.hasInfix "setup|sync|build-system|list|status|start|stop|upgrade|reset|android-config|inject|gc|resize|pack|unpack [vm...] [options]" vm_setup_sh_text)
        && (lib.hasInfix "inject <vm>" vm_setup_sh_text)
        && (lib.hasInfix "do_inject() {" vm_setup_sh_text)
        && (lib.hasInfix "inject requires a VM id" vm_setup_sh_text)
        && (lib.hasInfix "vm_inject_guest \"$vm_id\"" vm_setup_sh_text)
      )
      "scripts/vm.sh must wire the inject subcommand (usage, dispatch, do_inject with manifest validation, vm_inject_guest)";

  # The Windows twin must mirror the inject subcommand: ValidateSet, dispatch,
  # Invoke-VMInject with the running-VM guard and --force flag.
  test_vm_inject_windows_twin =
    assert'
      (
        (lib.hasInfix "reset', 'android-config', 'inject', 'resize', 'gc', 'pack', 'unpack'" vm_ps1_text)
        && (lib.hasInfix "'inject'  { Invoke-VMInject }" vm_ps1_text)
        && (lib.hasInfix "function Invoke-VMInject {" vm_ps1_text)
        && (lib.hasInfix "inject requires a VM id" vm_ps1_text)
        && (lib.hasInfix "VM '$vmName' is running; stop it before injecting" vm_ps1_text)
      )
      "scripts/vm.ps1 must mirror the inject subcommand (ValidateSet, dispatch, Invoke-VMInject, running-VM guard)";

  # Injection must dispatch by type: NixOS via qemu-nbd + nixos-enter
  # applying the guest config, Windows via libguestfs (virt-customize
  # --in-place), macOS via tart clone of the type base.  Android skips
  # injection entirely (userdata create + marker adoption only), and a
  # running VM is never injected underneath.
  test_vm_inject_dispatches_by_type = assert' (
    (lib.hasInfix "vm_inject_guest() {" vm_setup_sh_text)
    && (lib.hasInfix "vm_inject_nixos \"$_vig_name\"" vm_setup_sh_text)
    && (lib.hasInfix "vm_inject_windows \"$_vig_name\"" vm_setup_sh_text)
    && (lib.hasInfix "vm_inject_macos \"$_vig_name\"" vm_setup_sh_text)
    && (lib.hasInfix "no disk injection for Android VM" vm_setup_sh_text)
    && (lib.hasInfix "vm_inject_nixos() {" vm_setup_sh_text)
    && (lib.hasInfix "vm_inject_windows() {" vm_setup_sh_text)
    && (lib.hasInfix "vm_inject_macos() {" vm_setup_sh_text)
    && (lib.hasInfix "nixos-enter --root" vm_setup_sh_text)
    && (lib.hasInfix "virt-customize --in-place" vm_setup_sh_text)
    && (lib.hasInfix "tart clone" vm_setup_sh_text)
  ) "vm.sh must dispatch injection by type (vm_inject_guest, per-type implementations, Android skip)";

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
        && (lib.hasInfix "variable \"hostfwd\"" vms_windows_packer_text)
        && (lib.hasInfix "\${var.hostfwd}" vms_windows_packer_text)
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
      "Windows VM packer template must use SSH communicator with hostfwd driven by the required hostfwd variable and expose controlled firmware/debug knobs";

  # Autounattend.xml must configure OpenSSH before VirtIO driver scan to prevent blocking.
  test_windows_autounattend_ssh_before_virtio =
    assert'
      (
        (lib.hasInfix "<Order>1</Order>" vms_windows_autounattend_text)
        && (lib.hasInfix "Add-WindowsCapability -Online -Name OpenSSH.Server" vms_windows_autounattend_text)
        && (lib.hasInfix "<Order>3</Order>" vms_windows_autounattend_text)
        && (lib.hasInfix "VirtIO" vms_windows_autounattend_text)
      )
      "src/vms/Windows/Autounattend.xml must configure OpenSSH in Orders 1–3 before VirtIO driver scan so SSH is ready even if driver scan is slow";
  # BIOS installs need a normal NTFS partition type for the active system
  # partition. TypeID 0x27 is a recovery/hidden partition type and can leave
  # SeaBIOS stuck at "Booting from Hard Disk...".
  test_windows_autounattend_bios_system_partition_type =
    assert'
      (
        (lib.hasInfix "<TypeID>0x07</TypeID>" vms_windows_autounattend_text)
        && !(lib.hasInfix "<TypeID>0x27</TypeID>" vms_windows_autounattend_text)
      )
      "src/vms/Windows/Autounattend.xml must keep the active BIOS system partition TypeID at 0x07 (not 0x27)";

  # Guest credential policy: username/password must resolve from per-user SOPS
  # secrets via vmGuest secret-key references and stay wired across all guest
  # build paths. vmGuest lives in src/users/<username>/vm-guest.json and is
  # assembled by load-user-registry.sh / users-registry.nix.
  test_guest_credentials_policy_in_user_registries = assert' (
    (lib.hasInfix "\"usernameSecretKey\": \"vm_guest_username\"" vm_guest_json_text)
    && (lib.hasInfix "\"passwordSecretKey\": \"vm_guest_password\"" vm_guest_json_text)
  ) "default vm-guest.json must declare vmGuest secret-key references";

  test_guest_credentials_policy_in_user_secrets = assert' (
    (lib.hasInfix "vm_guest_username:" user_secret_text)
    && (lib.hasInfix "vm_guest_password:" user_secret_text)
  ) "fixture test-user.yml must contain secret-backed VM guest username/password keys";

  test_guest_credentials_policy_in_vm_setup_sh =
    assert'
      (
        (lib.hasInfix "resolve_vm_guest_credentials" vm_setup_sh_text)
        && (lib.hasInfix "load-user-registry.sh" vm_setup_sh_text)
        && (lib.hasInfix "src/users" vm_setup_sh_text)
        && (lib.hasInfix "users/\${_rvgc_owner}.yml" vm_setup_sh_text)
        && (lib.hasInfix "vmGuest.usernameSecretKey" vm_setup_sh_text)
        && (lib.hasInfix "vmGuest.passwordSecretKey" vm_setup_sh_text)
        && (lib.hasInfix "decrypt-sops.sh" vm_setup_sh_text)
        && (lib.hasInfix "NUCLEUS_VM_GUEST_USERNAME" vm_setup_sh_text)
        && (lib.hasInfix "NUCLEUS_VM_GUEST_PASSWORD" vm_setup_sh_text)
      )
      "scripts/vm.sh must resolve guest credentials from per-user SOPS secrets and export/pass them to guest builders";

  test_nixos_generators_uses_exported_env_credentials =
    assert'
      (
        (lib.hasInfix "guestUsername = builtins.getEnv \"NUCLEUS_VM_GUEST_USERNAME\"" guest_vm_nix_text)
        && (lib.hasInfix "guestPassword = builtins.getEnv \"NUCLEUS_VM_GUEST_PASSWORD\"" guest_vm_nix_text)
        && !(lib.hasInfix "--argstr guestUsername" vm_setup_sh_text)
        && !(lib.hasInfix "--argstr guestPassword" vm_setup_sh_text)
      )
      "scripts/vm.sh must let nixos-generators consume exported guest credentials directly instead of passing unsupported --argstr flags";

  test_guest_credentials_policy_in_windows_vm_setup_ps1 =
    assert'
      (
        (lib.hasInfix "Resolve-VMGuestCredential" windows_vm_setup_ps1_text)
        && (lib.hasInfix "Load-UserRegistry.ps1" windows_vm_setup_ps1_text)
        && (lib.hasInfix "src\\secrets\\users\\$secretOwner.yml" windows_vm_setup_ps1_text)
        && (lib.hasInfix "vmGuest secret-key references" windows_vm_setup_ps1_text)
        && (lib.hasInfix "--decrypt --output-type json" windows_vm_setup_ps1_text)
        && (lib.hasInfix "-GuestAccountName $guestUsername -GuestSecret $guestPassword" windows_vm_setup_ps1_text)
        && (lib.hasInfix "-GuestSecretHash $guestSecretHash" windows_vm_setup_ps1_text)
        && (lib.hasInfix "__NUCLEUS_GUEST_USERNAME__" windows_vm_setup_ps1_text)
        && (lib.hasInfix "__NUCLEUS_GUEST_PASSWORD__" windows_vm_setup_ps1_text)
      )
      "Invoke-VMSetup.ps1 must resolve and propagate secret-backed guest credentials to all Windows-host build paths";

  test_guest_credentials_policy_in_nixos_guest = assert' (
    (lib.hasInfix "guestUsername = builtins.getEnv \"NUCLEUS_VM_GUEST_USERNAME\"" guest_vm_nix_text)
    && (lib.hasInfix "guestPassword = builtins.getEnv \"NUCLEUS_VM_GUEST_PASSWORD\"" guest_vm_nix_text)
    && (lib.hasInfix "users.users.\"\${guestUsername}\"" guest_vm_nix_text)
  ) "src/vms/guests/NixOS/guest.nix must consume exported guest credentials and create a login user";

  test_guest_credentials_policy_in_nixos_packer =
    assert'
      (
        (lib.hasInfix "variable \"guest_username\"" nixos_packer_text)
        && (lib.hasInfix "variable \"guest_password\"" nixos_packer_text)
        && (lib.hasInfix "users.users.\"\${var.guest_username}\"" nixos_packer_text)
        && !(lib.hasInfix "default     = \"nixos\"" nixos_packer_text)
      )
      "src/vms/NixOS/packer.pkr.hcl must accept and apply guest credentials for Windows-host NixOS builds";

  test_windows_nixos_build_honors_manifest_disk_size =
    assert'
      (
        (lib.hasInfix "-DiskBytes $diskBytes" windows_vm_setup_ps1_text)
        && (lib.hasInfix "[string]$DiskBytes" windows_vm_setup_ps1_text)
        && (lib.hasInfix "-var \"disk_size=\${DiskBytes}\"" windows_vm_setup_ps1_text)
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
      "src/vms/Windows/packer.pkr.hcl must wire guest credentials into SSH communicator and consume a rendered Autounattend path";

  test_guest_credentials_policy_in_windows_autounattend =
    assert'
      (
        (lib.hasInfix "__NUCLEUS_GUEST_USERNAME__" vms_windows_autounattend_text)
        && (lib.hasInfix "__NUCLEUS_GUEST_PASSWORD__" vms_windows_autounattend_text)
      )
      "src/vms/Windows/Autounattend.xml must expose guest credential placeholders for runtime rendering";

  test_guest_credentials_policy_in_macos_packer =
    assert'
      (
        (lib.hasInfix "variable \"guest_username\"" vms_macos_packer_text)
        && (lib.hasInfix "variable \"guest_password\"" vms_macos_packer_text)
        && (lib.hasInfix "sysadminctl -addUser" vms_macos_packer_text)
      )
      "src/vms/macOS/packer.pkr.hcl must provision a guest account using the secret-backed guest credential policy";

  # The NixOS guest must thread username (and hostName) through _module.args
  # because nixos-generators passes no specialArgs; shared modules key off both.
  test_nixos_guest_threads_username_arg =
    assert'
      (
        (lib.hasInfix "_module.args = {" guest_vm_nix_text)
        && (lib.hasInfix "username = guestUsername;" guest_vm_nix_text)
        && (lib.hasInfix "builtins.getEnv \"NUCLEUS_VM_GUEST_HOSTNAME\"" guest_vm_nix_text)
        && !(lib.hasInfix "hostName = \"NixOS\";" guest_vm_nix_text)
      )
      "src/vms/guests/NixOS/guest.nix must thread username/hostName via _module.args (hostName from NUCLEUS_VM_GUEST_HOSTNAME) for per-VM nixos-generators evals";

  # The per-VM guest hostname must reach every build path: exported to guest
  # builds via the NUCLEUS_VM_GUEST_HOSTNAME env var, rendered into the NixOS
  # packer configuration.nix, and tokenized in Autounattend.xml.
  test_vm_guest_hostname_env_export = assert' (lib.hasInfix "export NUCLEUS_VM_GUEST_HOSTNAME" vm_setup_sh_text) "vm.sh must export NUCLEUS_VM_GUEST_HOSTNAME for guest builds";

  test_nixos_packer_guest_hostname_var = assert' (
    (lib.hasInfix "variable \"guest_hostname\"" nixos_packer_text)
    && (lib.hasInfix "networking.hostName = \"\${var.guest_hostname}\";" nixos_packer_text)
  ) "NixOS packer must take a required guest_hostname variable and render it into configuration.nix";

  test_windows_autounattend_guest_hostname_token =
    assert'
      (
        (lib.hasInfix "__GUEST_HOSTNAME__" vms_windows_autounattend_text)
        && (lib.hasInfix ".Replace('__GUEST_HOSTNAME__'" windows_vm_setup_ps1_text)
      )
      "Autounattend.xml must expose __GUEST_HOSTNAME__ and Invoke-VMSetup.ps1 must replace it from the manifest hostname";

  # The NixOS guest must force overrides on host modules whose defaults cannot
  # evaluate on aarch64-linux or collide under the standalone evaluation.
  test_nixos_guest_standalone_eval_overrides =
    assert'
      (
        (lib.hasInfix "services.gnome.gcr-ssh-agent.enable = lib.mkForce false;" base_guest_nix_text)
        && (lib.hasInfix "hardware.graphics.enable32Bit = lib.mkForce false;" base_guest_nix_text)
        && (lib.hasInfix "programs.steam.enable = lib.mkForce false;" base_guest_nix_text)
        && (lib.hasInfix "system.stateVersion = lib.mkForce \"25.05\";" base_guest_nix_text)
        && (lib.hasInfix "allowUnfree = true;" base_guest_nix_text)
        && (lib.hasInfix "permittedInsecurePackages = [ \"dotnet-runtime-6.0.36\" ];" base_guest_nix_text)
      )
      "src/vms/NixOS/base-guest.nix must force standalone-eval overrides (gcr-ssh-agent, 32-bit graphics, Steam, stateVersion, unfree/insecure policy)";

  # vm.sh must provision UTM data disks from the type system image: the data
  # disk is a qcow2 overlay over src/<type>/system image.qcow2 hard-linked into
  # the UTM bundle (data preservation: an existing data disk is never recreated
  # during setup; the old overlay-backing base link is gone).
  test_utm_base_overlay_provisioning =
    assert'
      (
        (lib.hasInfix "vm_provision_one \"\$vm_id\"" vm_setup_sh_text)
        && (lib.hasInfix "linked data disk into UTM bundle: \$disk_file" vm_setup_sh_text)
        && !(lib.hasInfix "_base_link=\"\$data_dir/\$(basename \"\$(vm_src_path \"\$vm_type\" \"\$VM_OVERLAY_BACKING\")\")\"" vm_setup_sh_text)
        && !(lib.hasInfix "linked base image into UTM bundle: \$_base_link" vm_setup_sh_text)
      )
      "scripts/vm.sh must provision UTM data disks as qcow2 overlays over src/<type>/system image.qcow2 hard-linked into the bundle";

  # Windows vm-setup must mirror POSIX data-disk provisioning: the data disk
  # is a qcow2 overlay data/<id>.qcow2 backed by src/<type>/system image.qcow2
  # (absolute backing path), existing data disks are preserved (provision
  # drift warns for in-place injection only while the VM is stopped), growth
  # is grow-only via qemu-img resize, and Android userdata is a standalone
  # data/ qcow2.
  test_windows_base_overlay_parity =
    assert'
      (
        (lib.hasInfix "Get-VMSystemImagePath -SrcDir $srcDir -Type $vm.type" windows_vm_setup_ps1_text)
        && (lib.hasInfix "& \$qemuImg create -f qcow2 -b \$backing -F qcow2 \$diskPath" windows_vm_setup_ps1_text)
        && !(lib.hasInfix "Copy-Item \$prebuilt \$basePath" windows_vm_setup_ps1_text)
        && (lib.hasInfix "Test-VMProcessRunning -VmId \$vm.id -VmDisplay \$vm.name" windows_vm_setup_ps1_text)
        && (lib.hasInfix "function Get-VMRunningProcessNameList" windows_vm_setup_ps1_text)
        && (lib.hasInfix "Get-VMRunningProcessNameList" vm_ps1_text)
        && (lib.hasInfix "Get-VMQcow2VirtualSize -ImagePath \$diskPath" windows_vm_setup_ps1_text)
        && (lib.hasInfix "\$qemuImg resize \$diskPath \$diskBytes" windows_vm_setup_ps1_text)
        && (lib.hasInfix "vm.id).qcow2" windows_vm_setup_ps1_text)
        && (lib.hasInfix "Join-Path -Path \$dataDir -ChildPath \"\$(\$vm.id) (system).qcow2\"" windows_vm_setup_ps1_text)
        && (lib.hasInfix "& \$qemuImg create -f qcow2 -b \$systemImage -F qcow2 \$systemOverlayPath" windows_vm_setup_ps1_text)
      )
      "Windows vm-setup must provision data/<id>.qcow2 overlays over src/<type>/system image.qcow2 (absolute backing, data preservation, grow-only resize, Android standalone userdata and data/<id> (system).qcow2 system overlay)";

  # The POSIX Windows/QEMU vm-setup callback must provision data disks for
  # Windows guests (parity with the PowerShell Pass A): the vm_provision_one
  # call is what actually creates the writable data disk data/<id>.qcow2 on the
  # Windows host.
  test_windows_qemu_ensure_base_and_overlay = assert' (
    (lib.hasInfix "vm_setup_windows_qemu()" vm_setup_sh_text)
    && (lib.hasInfix "vm_provision_one \"\$vm_id\"" vm_setup_sh_text)
    && (lib.hasInfix "data disk ready: \$disk_path" vm_setup_sh_text)
  ) "vm_setup_windows_qemu must call vm_provision_one for Windows guests";

  # UTM provisioning for Android must derive the system/userdata/GSI image
  # filenames from the manifest Android group (never hardcoded android-*
  # literals), validate the prebuilt with the relaxed 4 GiB floor, and
  # hard-link system/userdata/optional-GSI into the bundle (never copy).
  test_utm_android_uses_shared_images =
    assert'
      (
        (lib.hasInfix ''_android_system="$(vm_src_path Android "$(jq -r ".VMs[$vm_index].Android.systemImage" "$MANIFEST")")"'' vm_setup_sh_text)
        && (lib.hasInfix "_android_userdata=\"\$VM_DIR/data/\${vm_id}.qcow2\"" vm_setup_sh_text)
        && (lib.hasInfix ''_android_gsi="$(vm_src_path Android "$(jq -r ".VMs[$vm_index].Android.gsiImage" "$MANIFEST")")"'' vm_setup_sh_text)
        && (lib.hasInfix ''_prebuilt="$_android_system"'' vm_setup_sh_text)
        && (lib.hasInfix "_prebuilt_min_size=\"\$(parse_size \"\$(jq -r \".VMs[\$vm_index].minImageSize\" \"\$MANIFEST\")\")\"" vm_setup_sh_text)
        && (lib.hasInfix "linked Android system overlay into UTM bundle" vm_setup_sh_text)
        && (lib.hasInfix "linked Android userdata disk" vm_setup_sh_text)
        && (lib.hasInfix "Android userdata image not found" vm_setup_sh_text)
        && !(lib.hasInfix "cp \"\$_android_system\" \"\$disk_file\"" vm_setup_sh_text)
      )
      "scripts/vm.sh must provision Android UTM bundles from the manifest Android group image names, hard-linking canonical data/ overlays and src/Android/ payloads into the bundle (never copying)";

  # UTM bundles must expose canonical disks as hard links only — never copies
  # (no cp into bundle Data/), across all Darwin bundle writers (setup, build
  # refresh, unpack) — so bundles track canonical data/ and src/ inodes and
  # stay cheap to re-create; no legacy disk-main.qcow2 anywhere.
  test_utm_bundle_hard_link_only =
    assert'
      (
        (lib.hasInfix "ln -f \"\$VM_DIR/data/\${vm_id} (system).qcow2\" \"\$disk_file\"" vm_setup_sh_text)
        && (lib.hasInfix "_bai_system_overlay=\"\$VM_DIR/data/\${_bai_vm_id} (system).qcow2\"" vm_setup_sh_text)
        && (lib.hasInfix "ln -f \"\$_uv_android_userdata\" \"\$_uv_bundle/Data/user data.qcow2\"" vm_setup_sh_text)
        && (lib.hasInfix "ln -f \"\$VM_DIR/data/\${_uv_name}.qcow2\" \"\$_uv_bundle/Data/system disk.qcow2\"" vm_setup_sh_text)
        && (lib.hasInfix "vm_link_system_base_to_utm_bundle" vm_setup_sh_text)
        && (lib.hasInfix "system base.qcow2" vm_setup_sh_text)
        && !(lib.hasInfix "cp \"\$_bai_system_img\" \"\$_bai_bundle_system\"" vm_setup_sh_text)
        && !(lib.hasInfix "cp \"\$_uv_android_system\" \"\$_uv_bundle/Data/disk-main.qcow2\"" vm_setup_sh_text)
        && !(lib.hasInfix "cp \"\$_android_system\" \"\$disk_file\"" vm_setup_sh_text)
        && !(lib.hasInfix "disk-main.qcow2" vm_setup_sh_text)
        && !(lib.hasInfix "disk-main.qcow2" readmeTemplateText)
        && !(lib.hasInfix "disk-main.qcow2" utmConfigPlistText)
      )
      "UTM bundle disks must be hard links to canonical data//src/ files (never copies) with guest-agnostic names, a bundle-local system base backing link (UTM sandbox), and no legacy disk-main.qcow2 anywhere";

  # Android userdata must never delete standalone bundle copies; canonical
  # data/<id>.qcow2 is the source of truth and sync must re-link it (no
  # legacy bundle-only migration paths).
  test_android_userdata_hard_link_no_legacy_paths =
    assert'
      (
        (lib.hasInfix "vm_link_android_userdata_to_utm_bundle" vm_setup_sh_text)
        && !(lib.hasInfix "exists only in the UTM bundle" vm_setup_sh_text)
        && (lib.hasInfix "vm_link_android_userdata_to_utm_bundle \"\$vm_id\" \"\$vm_index\" \"\$bundle/Data\"" vm_setup_sh_text)
        && (lib.hasInfix "_lautb_bundle=\"\$_lautb_bundle_data_dir/user data.qcow2\"" vm_setup_sh_text)
        && !(lib.hasInfix "removing legacy bundle userdata" vm_setup_sh_text)
        && !(lib.hasInfix "pre-migration" vm_setup_sh_text)
      )
      "Android userdata must hard-link from canonical data/<id>.qcow2 without deleting standalone bundle copies";

  test_libvirt_android_userdata_canonical_path =
    assert'
      (
        (lib.hasInfix "vm_setup_libvirt()" vm_setup_sh_text)
        && (lib.hasInfix "_android_userdata=\"\$VM_DIR/data/\${vm_id}.qcow2\"" vm_setup_sh_text)
        && (lib.hasInfix "vm_ensure_android_system_overlay \"\$vm_id\"" vm_setup_sh_text)
      )
      "vm_setup_libvirt must validate Android userdata at data/<id>.qcow2 and ensure the data/<id> (system).qcow2 system overlay";

  # vm_ensure_android_system_overlay must create data/<name> (system).qcow2 as
  # a qcow2 overlay backed onto the Android system image (bundle-local system
  # base on macOS; src/ elsewhere) (create-once/preserve, provision marker,
  # Android semantics) and be wired into libvirt and windows-qemu Android
  # setup.
  test_vm_ensure_android_system_overlay =
    assert'
      (
        (lib.hasInfix "vm_ensure_android_system_overlay() {" vm_setup_sh_text)
        && (lib.hasInfix "_easo_disk=\"\$VM_DIR/data/\${_easo_name} (system).qcow2\"" vm_setup_sh_text)
        && (lib.hasInfix "qemu-img create -f qcow2 -b \"\$_easo_backing\" -F qcow2 \"\$_easo_disk\"" vm_setup_sh_text)
        && (lib.hasInfix "vm_system_overlay_backing \"\$_easo_name\" Android" vm_setup_sh_text)
        && (lib.hasInfix "vm_link_system_base_to_utm_bundle \"\$_easo_name\" Android" vm_setup_sh_text)
        && (lib.hasInfix "Android system overlay already exists" vm_setup_sh_text)
        && (lib.hasInfix "Android system overlay is invalid for" vm_setup_sh_text)
        && !(lib.hasInfix "qemu-img create -f qcow2 -b \"\$_easo_disk\"" vm_setup_sh_text)
      )
      "vm_ensure_android_system_overlay must create data/<name> (system).qcow2 as a qcow2 overlay backed onto the Android system image (bundle-local system base on macOS; create-once/preserve, never self-rebase)";

  # vm_setup_windows_qemu must also ensure the Android system overlay for
  # windows-qemu guests (parity with vm_setup_libvirt and the PowerShell
  # Pass A Android branch).
  test_windows_qemu_android_system_overlay = assert' (
    (lib.hasInfix "vm_setup_windows_qemu()" vm_setup_sh_text)
    && (lib.hasInfix "vm_ensure_android_system_overlay \"\$vm_id\"" vm_setup_sh_text)
  ) "vm_setup_windows_qemu must ensure the data/<id> (system).qcow2 Android system overlay";

  # The Android build must strip the whitespace wc -c pads its output with
  # (macOS pads, Linux does not); otherwise the size leaks into the selected
  # qcow2 path and cp fails, aborting the build.
  test_android_build_strips_wc_padding =
    assert'
      (
        (lib.hasInfix "wc -c <\"\$_f\" | tr -d '[:space:]'" vm_setup_sh_text)
        && (lib.hasInfix "sort -rn | head -1 | cut -d' ' -f2-" vm_setup_sh_text)
      )
      "scripts/vm.sh must strip wc -c whitespace padding when selecting the largest qcow2 from the extracted LineageOS bundle";

  # The Android build must size the userdata disk from the manifest's
  # diskSize (exact bytes) instead of a hardcoded 8 GiB; otherwise the
  # VMs.json diskSize setting is silently ignored.
  test_android_build_honors_manifest_disk_size =
    assert'
      (
        (lib.hasInfix ".VMs[\$_bai_vm_index].diskSize" vm_setup_sh_text)
        && (lib.hasInfix "_bai_disk_bytes=\"\$(parse_size \"\$(jq -r \".VMs[\$_bai_vm_index].diskSize\" \"\$MANIFEST\")\")\"" vm_setup_sh_text)
        && (lib.hasInfix "qemu-img create -f qcow2 \"\$_bai_userdata_img\" \"\$_bai_disk_bytes\"" vm_setup_sh_text)
        && (lib.hasInfix "creating userdata disk (\${_bai_disk_bytes} bytes)..." vm_setup_sh_text)
      )
      "scripts/vm.sh must size the Android userdata disk from the exact manifest diskSize bytes, not a hardcoded 8 GiB";

  # After a rebuild replaces a canonical disk (system image re-download or
  # userdata reset), an existing UTM bundle must re-link/re-copy it so UTM
  # boots the new inode; do_upgrade/do_reset call vm_build_android directly
  # without the vm_setup_utm_vms provisioning pass, which is what normally
  # keeps bundle links fresh (P5 re-link refresh).
  test_android_build_relink_refresh =
    assert'
      (
        (lib.hasInfix "_bai_system_replaced=false" vm_setup_sh_text)
        && (lib.hasInfix "_bai_userdata_replaced=false" vm_setup_sh_text)
        && (lib.hasInfix "_bai_system_replaced=true" vm_setup_sh_text)
        && (lib.hasInfix "_bai_userdata_replaced=true" vm_setup_sh_text)
        && (lib.hasInfix "vm_link_android_userdata_to_utm_bundle \"\$_bai_vm_id\" \"\$_bai_vm_index\" \"\$_bai_bundle_dir\"" vm_setup_sh_text)
        && (lib.hasInfix "_bai_system_overlay=\"\$VM_DIR/data/\${_bai_vm_id} (system).qcow2\"" vm_setup_sh_text)
        && (lib.hasInfix "_bai_bundle_system=\"\$_bai_bundle_dir/system disk.qcow2\"" vm_setup_sh_text)
        && (lib.hasInfix "ln -f \"\$_bai_system_overlay\" \"\$_bai_bundle_system\"" vm_setup_sh_text)
        && (lib.hasInfix "refreshed Android system disk in UTM bundle" vm_setup_sh_text)
        && (lib.hasInfix "if [ \"\$dry_run\" = false ]; then" vm_setup_sh_text)
        && (lib.hasInfix "_bai_bundle_dir=\"\$VM_DIR/\${_bai_vm_id}.utm/Data\"" vm_setup_sh_text)
        && !(lib.hasInfix "cp \"\$_bai_system_img\" \"\$_bai_bundle_system\"" vm_setup_sh_text)
      )
      "vm_build_android must re-link the UTM bundle's Android userdata/system disks after replacing a canonical disk (system re-download or userdata reset) so do_upgrade/do_reset do not leave stale bundle inodes";

  test_libvirt_runtime_validation_parity =
    assert'
      (
        (lib.hasInfix "failed to start libvirt default network" vm_setup_sh_text)
        && (lib.hasInfix "failed to mark libvirt default network for autostart" vm_setup_sh_text)
        && (lib.hasInfix "validate_qcow2_image \"$_prebuilt\" \"pre-built image for \${vm_id}\" \"$_prebuilt_min_size\"" vm_setup_sh_text)
        && (lib.hasInfix "disk_path=\"\$VM_DIR/data/\${vm_id}.qcow2\"" vm_setup_sh_text)
        && (lib.hasInfix "vm_provision_one \"\$vm_id\"" vm_setup_sh_text)
        && (lib.hasInfix "data disk ready: \$disk_path" vm_setup_sh_text)
      )
      "scripts/vm.sh must validate libvirt system images against the manifest minImageSize, provision the data/<id>.qcow2 overlay, and surface default-network recovery failures";

  # vm_provision_one is the phase-2 per-VM provision orchestrator: it derives
  # the type, disk path, and sidecar markers from NAME alone, delegates
  # create/keep to the NAME-only vm_ensure_data_disk, and owns the provision
  # drift message (setup never auto-injects or auto-recreates on drift — the
  # operator runs 'nucleus-vm inject NAME' while stopped).
  test_vm_provision_one_orchestrator =
    assert'
      (
        (lib.hasInfix "vm_provision_one() {" vm_setup_sh_text)
        && (lib.hasInfix "if ! vm_ensure_data_disk \"\$_vpo_name\"; then" vm_setup_sh_text)
        && (lib.hasInfix "guest provision drift detected for '\$_vpo_name'" vm_setup_sh_text)
        && (lib.hasInfix "vm_ensure_data_disk() {" vm_setup_sh_text)
        && (lib.hasInfix "local _edd_name=\"\$1\"" vm_setup_sh_text)
        && (lib.hasInfix "vm_provision_one \"\$vm_id\"" vm_setup_sh_text)
      )
      "vm_provision_one must orchestrate per-VM provision over the NAME-only vm_ensure_data_disk with the drift message in the orchestrator";

  # vm_ensure_data_disk is the data-preservation core: an existing valid data
  # disk is never recreated/truncated/re-based, an invalid disk warns and
  # defers to 'nucleus-vm reset' unless --force, and growth is strictly
  # grow-only toward the manifest diskSize.
  test_vm_ensure_data_disk_preservation =
    assert'
      (
        (lib.hasInfix "say \"data disk already exists: \$_edd_disk\"" vm_setup_sh_text)
        && !(lib.hasInfix "adopting missing provision marker" vm_setup_sh_text)
        && (lib.hasInfix "warn \"data disk is invalid for '\$_edd_name': \$_edd_disk\"" vm_setup_sh_text)
        && (lib.hasInfix "warn \"run 'nucleus-vm reset \$_edd_name' to recreate it (or pass --force)\"" vm_setup_sh_text)
        && (lib.hasInfix "warn \"recreating data disk for '\$_edd_name' (--force; this DESTROYS existing data)\"" vm_setup_sh_text)
        && (lib.hasInfix "say \"growing data disk for '\$_edd_name' from \$_edd_virtual_size to \$_edd_disk_bytes bytes\"" vm_setup_sh_text)
        && (lib.hasInfix "qemu-img create -f qcow2 -b \"\$_edd_backing\" -F qcow2 \"\$_edd_disk\"" vm_setup_sh_text)
      )
      "vm_ensure_data_disk must preserve existing data disks (skip-if-exists, invalid-disk reset guard, grow-only resize)";

  # Android provision drift is marker-adoption-only: Android userdata is
  # created empty and never injected, so a stale marker just means inputs
  # changed — vm_provision_one adopts it without reporting drift or touching
  # the disk.
  test_vm_provision_android_marker_adoption_only =
    assert'
      (
        (lib.hasInfix "if [ \"\$_vpo_type\" = \"Android\" ]; then" vm_setup_sh_text)
        && (lib.hasInfix "no injection, no drift report" vm_setup_sh_text)
        && (lib.hasInfix "vm_provision_one() {" vm_setup_sh_text)
      )
      "vm_provision_one must treat Android provision drift as marker-adoption-only (no injection, no drift report)";

  # Windows vm-setup must mirror the same data-preservation invariants:
  # existing disks kept (skip-if-exists), invalid disks warned for
  # 'nucleus-vm reset', grow-only resize, and Android userdata
  # skip-if-exists with marker adoption.
  test_windows_vm_data_disk_preservation =
    assert'
      (
        (lib.hasInfix "vm-setup: data disk already exists: \$diskPath" windows_vm_setup_ps1_text)
        && !(lib.hasInfix "adopting missing provision marker" windows_vm_setup_ps1_text)
        && (lib.hasInfix "vm-setup: data disk is invalid for '\$(\$vm.id)': \$diskPath; run 'nucleus-vm reset \$(\$vm.id)' to recreate it (data preserved)" windows_vm_setup_ps1_text)
        && (lib.hasInfix "vm-setup: growing data disk '\$(\$vm.id)' from \$dataDiskSize to \$diskBytes bytes (grow-only)" windows_vm_setup_ps1_text)
        && (lib.hasInfix "vm-setup: Android userdata disk already exists: \$userdataPath" windows_vm_setup_ps1_text)
      )
      "Windows vm-setup must preserve existing data disks (skip-if-exists, invalid-disk reset guard, grow-only resize, Android userdata parity)";

  # vm_build_android must skip existing canonical disks: the system image and
  # userdata are preserved unless --upgrade/--reset opt in (skip-if-exists),
  # mirroring data preservation for the Android standalone userdata path.
  test_vm_android_build_skip_if_exists =
    assert'
      (
        (lib.hasInfix "say \"system image already exists: \$_bai_system_img\"" vm_setup_sh_text)
        && (lib.hasInfix "say \"userdata disk already exists: \$_bai_userdata_img\"" vm_setup_sh_text)
      )
      "vm_build_android must skip existing system/userdata disks (skip-if-exists; --upgrade/--reset opt into replacement)";

  # The shared Android start script must expose manifest-driven tokens for CPU
  # count, RAM, image filenames, and port forwards instead of hardcoded values.
  test_android_start_script_tokens =
    assert'
      (
        (lib.hasInfix "__ANDROID_CPU_COUNT__" start_android_ps1_text)
        && (lib.hasInfix "__ANDROID_RAM_BYTES__" start_android_ps1_text)
        && (lib.hasInfix "__ANDROID_SYSTEM_IMAGE__" start_android_ps1_text)
        && (lib.hasInfix "__ANDROID_USERDATA_IMAGE__" start_android_ps1_text)
        && (lib.hasInfix "__ANDROID_GSI_IMAGE__" start_android_ps1_text)
        && (lib.hasInfix "__ANDROID_NVRAM_IMAGE__" start_android_ps1_text)
        && (lib.hasInfix "__HOSTFWDS__" start_android_ps1_text)
      )
      "start-android-vm.ps1 must expose __ANDROID_CPU_COUNT__/__ANDROID_RAM_BYTES__/__ANDROID_SYSTEM_IMAGE__/__ANDROID_USERDATA_IMAGE__/__ANDROID_GSI_IMAGE__/__ANDROID_NVRAM_IMAGE__/__HOSTFWDS__ tokens for manifest-driven rendering";

  # start-android-vm.ps1 must attach the system drive as the writable
  # data/<id> (system).qcow2 overlay (rendered leaf), keep userdata under data/,
  # and keep the GSI payload under src/Android/ read-only (readonly=on).
  test_start_android_system_overlay_data_dir =
    assert'
      (
        (lib.hasInfix "Join-Path \$dataDir '__ANDROID_SYSTEM_IMAGE__'" start_android_ps1_text)
        && (lib.hasInfix "Join-Path \$dataDir '__ANDROID_USERDATA_IMAGE__'" start_android_ps1_text)
        && (lib.hasInfix "Join-Path \$dataDir '__ANDROID_NVRAM_IMAGE__'" start_android_ps1_text)
        && (lib.hasInfix "Join-Path \$androidSrcDir '__ANDROID_GSI_IMAGE__'" start_android_ps1_text)
        && (lib.hasInfix "readonly=on,if=none,id=drive-gsi" start_android_ps1_text)
        && !(lib.hasInfix "Join-Path \$androidSrcDir '__ANDROID_SYSTEM_IMAGE__'" start_android_ps1_text)
        && !(lib.hasInfix "file=\$diskSystem,format=qcow2,readonly=on" start_android_ps1_text)
      )
      "start-android-vm.ps1 must resolve the system overlay and userdata under data/ and keep the GSI payload under src/Android/ read-only (readonly=on, system overlay never readonly)";

  # vm_write_start_script must render the Android tokens via a sed chain after
  # copying the shared file, preserving the android-vm-single-source invariant.
  test_vm_write_start_script_android_sed_chain =
    assert'
      (
        (lib.hasInfix "s|__ANDROID_CPU_COUNT__|" vm_setup_sh_text)
        && (lib.hasInfix "s|__ANDROID_RAM_BYTES__|" vm_setup_sh_text)
        && (lib.hasInfix "s|__ANDROID_SYSTEM_IMAGE__|" vm_setup_sh_text)
        && (lib.hasInfix "s|__ANDROID_USERDATA_IMAGE__|" vm_setup_sh_text)
        && (lib.hasInfix "s|__ANDROID_GSI_IMAGE__|" vm_setup_sh_text)
        && (lib.hasInfix "s|__ANDROID_NVRAM_IMAGE__|" vm_setup_sh_text)
        && (lib.hasInfix "s|__HOSTFWDS__|" vm_setup_sh_text)
      )
      "vm.sh must render Android start-script tokens (CPU/RAM/images/NVRAM/portForwards) via a sed chain after copying the shared file";

  # Both PowerShell renderers must emit the data/<id> (system).qcow2 overlay
  # leaf for __ANDROID_SYSTEM_IMAGE__ (never the pristine src/Android/
  # payload name), keeping the cross-host disk model in lockstep.
  test_android_system_overlay_render_leaves =
    assert'
      (
        (lib.hasInfix "Replace('__ANDROID_SYSTEM_IMAGE__', \"\$vmId (system).qcow2\")" vm_ps1_text)
        && (lib.hasInfix "Replace('__ANDROID_SYSTEM_IMAGE__', \"\$(\$Vm.id) (system).qcow2\")" windows_vm_setup_ps1_text)
        && (lib.hasInfix "_wss_system_image=\"\${_wss_id} (system).qcow2\"" vm_setup_sh_text)
        && !(lib.hasInfix "Replace('__ANDROID_SYSTEM_IMAGE__', [string]\$vmDoc.Android.systemImage)" vm_ps1_text)
        && !(lib.hasInfix "Replace('__ANDROID_SYSTEM_IMAGE__', [string]\$Vm.Android.systemImage)" windows_vm_setup_ps1_text)
      )
      "All three renderers must emit the data/<id> (system).qcow2 overlay leaf for __ANDROID_SYSTEM_IMAGE__, never the pristine src/Android/ payload name";

  # All three renderers must emit the per-VM UEFI NVRAM leaf
  # data/<id> (nvram).fd for __ANDROID_NVRAM_IMAGE__ (writable vars state,
  # seeded once by vm-setup; never the shared firmware vars template).
  test_android_nvram_render_leaves =
    assert'
      (
        (lib.hasInfix "Replace('__ANDROID_NVRAM_IMAGE__', \"\$vmId (nvram).fd\")" vm_ps1_text)
        && (lib.hasInfix "Replace('__ANDROID_NVRAM_IMAGE__', \"\$(\$Vm.id) (nvram).fd\")" windows_vm_setup_ps1_text)
        && (lib.hasInfix "_wss_nvram_image=\"\${_wss_id} (nvram).fd\"" vm_setup_sh_text)
        && (lib.hasInfix "s|__ANDROID_NVRAM_IMAGE__|" vm_setup_sh_text)
        && !(lib.hasInfix "Join-Path \$firmwareDir 'edk2-arm-vars.fd'" start_android_ps1_text)
      )
      "All three renderers must emit the data/<id> (nvram).fd leaf for __ANDROID_NVRAM_IMAGE__, never the shared firmware vars template";

  # macOS UTM adopts the UTM-generated Data/efi_vars.fd into the canonical
  # data/<id> (nvram).fd (writable per-VM vars state) and hard-links it back;
  # Windows Pass A seeds the same leaf once from the firmware vars template.
  test_android_nvram_macos_adoption_and_windows_seed =
    assert'
      (
        (lib.hasInfix "vm_link_nvram_to_utm_bundle()" vm_setup_sh_text)
        && (lib.hasInfix "\$VM_DIR/data/\${_lntb_name} (nvram).fd" vm_setup_sh_text)
        && (lib.hasInfix "ln -f \"\$_lntb_canonical\" \"\$_lntb_bundle\"" vm_setup_sh_text)
        && (lib.hasInfix "vm_link_nvram_to_utm_bundle \"\$vm_id\" \"\$data_dir\"" vm_setup_sh_text)
        && (lib.hasInfix "vm_link_nvram_to_utm_bundle \"\$_uv_name\" \"\$_uv_bundle/Data\"" vm_setup_sh_text)
        && (lib.hasInfix "Join-Path -Path \$dataDir -ChildPath \"\$(\$vm.id) (nvram).fd\"" windows_vm_setup_ps1_text)
        && (lib.hasInfix "edk2-arm-vars.fd" windows_vm_setup_ps1_text)
        && !(lib.hasInfix "pre-migration" vm_setup_sh_text)
      )
      "macOS must adopt UTM's Data/efi_vars.fd into data/<id> (nvram).fd (hard-linked back) and Windows must seed the same per-VM leaf from the firmware vars template";

  # Local Mido compatibility adjustments must be applied at runtime from a
  # repository-owned patch file, not by editing the vendored submodule files.
  test_windows_iso_mido_patch_file_exists = assert' (builtins.pathExists ../../src/vms/Windows/patches/mido-iso-link.patch) "src/vms/Windows/patches/mido-iso-link.patch must exist for runtime Mido patching";
  test_windows_iso_mido_runtime_patch_support =
    assert'
      (
        (lib.hasInfix "NUCLEUS_MIDO_PATCH_FILE" vm_setup_sh_text)
        && (lib.hasInfix "src/vms/Windows/patches/mido-iso-link.patch" vm_setup_sh_text)
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
        && (lib.hasInfix "__VM_MAIN_DRIVE_IMAGE__" utmConfigPlistText)
        && (lib.hasInfix "__VM_MAIN_DRIVE_READONLY__" utmConfigPlistText)
        && !(lib.hasInfix "disk-main.qcow2" utmConfigPlistText)
      )
      "src/modules/configs/vms/utm-config.plist.xml must include core UTM schema keys (Drive/ImageName/QEMU/Input) with guest-agnostic main-drive tokens (never a legacy disk-main.qcow2 literal)";
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
  # UTM's QEMU backend only emits hostfwd= for Mode=Emulated (user/slirp
  # networking); for Mode=Shared (vmnet-shared) the PortForward array is
  # silently ignored, so manifest port forwards (host ports 22000-22099)
  # become unreachable.  The template must stay on Emulated so vm.sh's
  # guest-wait checks actually work.
  test_macbook_utm_emulated_network_for_port_forward =
    assert'
      (
        (lib.hasInfix "<key>Mode</key>" utmConfigPlistText)
        && (lib.hasInfix "<string>Emulated</string>" utmConfigPlistText)
        && !(lib.hasInfix "<string>Shared</string>" utmConfigPlistText)
        && (lib.hasInfix "<key>PortForward</key>" utmConfigPlistText)
        && (lib.hasInfix "__VM_PORT_FORWARDS__" utmConfigPlistText)
        && !(lib.hasInfix "__VM_BASE_PORT_FORWARD__" utmConfigPlistText)
        && !(lib.hasInfix "__VM_ADDITIONAL_PORT_FORWARDS__" utmConfigPlistText)
      )
      "src/modules/configs/vms/utm-config.plist.xml must use Mode=Emulated (not Shared) so UTM forwards manifest portForwards via hostfwd; vmnet-shared silently drops PortForward";
  # UTM port forwards must map every manifest portForwards entry without
  # guestPort-based branching (each VM binds only its own host ports from
  # VMs.json, so concurrent VMs cannot collide on the same host port).
  test_macbook_utm_port_forwards_from_manifest =
    assert'
      (
        (lib.hasInfix "vm.portForwards" macbook_vms_nix_text)
        && (lib.hasInfix "portForwardEntries" macbook_vms_nix_text)
        && !(lib.hasInfix "guestPort == 22" macbook_vms_nix_text)
        && !(lib.hasInfix "guestPort != 22" macbook_vms_nix_text)
        && !(lib.hasInfix "<integer>2222</integer>" macbook_vms_nix_text)
        && (lib.hasInfix "__VM_PORT_FORWARDS__" utmConfigPlistText)
      )
      "src/hosts/MacBook/vms.nix must render all manifest portForwards via portForwardEntries into __VM_PORT_FORWARDS__ without guestPort-based branching";
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
        && (lib.hasInfix "disk_file=\"$data_dir/system disk.qcow2\"" vm_setup_sh_text)
      )
      "scripts/vm.sh must place UTM system disk.qcow2 under bundle Data/ to match the guest-agnostic ImageName-based UTM drive resolution";
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
    && (lib.hasInfix "run home-manager switch (or nucleus apply) before vm sync" vm_setup_sh_text)
  ) "scripts/vm.sh must fail fast on stale UTM templates and print the recovery action";
  test_macbook_utm_required_key_guard = assert' (
    (lib.hasInfix "_required_utm_keys" vm_setup_sh_text)
    && (lib.hasInfix "_missing_utm_keys" vm_setup_sh_text)
    && (lib.hasInfix "stale or incomplete UTM template detected" vm_setup_sh_text)
    && (lib.hasInfix "<key>IconCustom</key>" vm_setup_sh_text)
    && (lib.hasInfix "<key>UsbBusSupport</key>" vm_setup_sh_text)
  ) "scripts/vm.sh must block incomplete UTM templates missing required keys";
  test_vm_readme_template_content =
    assert'
      (
        (lib.hasInfix "nucleus-vm setup" readmeTemplateText)
        && (lib.hasInfix "## Layout" readmeTemplateText)
        && (lib.hasInfix "Packer/" readmeTemplateText)
        && (lib.hasInfix "installer.iso" readmeTemplateText)
        && (lib.hasInfix "## Start commands" readmeTemplateText)
        && (lib.hasInfix "start-<id>.sh" readmeTemplateText)
        && (lib.hasInfix "start-<id>.ps1" readmeTemplateText)
        && (lib.hasInfix "vm-management.instructions.md" readmeTemplateText)
        && (lib.hasInfix "## Troubleshooting" readmeTemplateText)
        && (lib.hasInfix "__VM_DIR_DISPLAY__" readmeTemplateText)
        && (lib.hasInfix "system disk.qcow2" readmeTemplateText)
        && (lib.hasInfix "user data.qcow2" readmeTemplateText)
        && (lib.hasInfix "GSI disk.qcow2" readmeTemplateText)
        && (lib.hasInfix "efi_vars.fd" readmeTemplateText)
        && (lib.hasInfix "(nvram).fd" readmeTemplateText)
        && !(lib.hasInfix "disk-main.qcow2" readmeTemplateText)
        && !(lib.hasInfix "<userdataImage>" readmeTemplateText)
        && !(lib.hasInfix "<gsiImage>" readmeTemplateText)
        && (!lib.hasInfix "{{" readmeTemplateText)
      )
      "src/vms/templates/README.md must contain expected template sections and __TOKEN__ placeholders, with no {{TOKEN}} style";

  test_vm_start_posix_template_content = assert' (
    (lib.hasInfix "__VM_ID__" startPosixTemplateText)
    && (lib.hasInfix "__VM_DISPLAY__" startPosixTemplateText)
    && (lib.hasInfix "__HOST_KIND__" startPosixTemplateText)
    && (lib.hasInfix "__VM_DIR__" startPosixTemplateText)
    && (lib.hasInfix "__TART_SOFTNET_EXPOSE__" startPosixTemplateText)
    && (lib.hasInfix "darwin-tart" startPosixTemplateText)
    && (lib.hasInfix "darwin-utm" startPosixTemplateText)
    && (lib.hasInfix "nixos-libvirt" startPosixTemplateText)
    && (lib.hasInfix "tart run" startPosixTemplateText)
    && (lib.hasInfix "--net-softnet" startPosixTemplateText)
    && (lib.hasInfix "--net-softnet-expose" startPosixTemplateText)
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
        && (lib.hasInfix "__VM_ID__" startHostPs1TemplateText)
        && (lib.hasInfix "__VM_DISPLAY__" startHostPs1TemplateText)
        && (lib.hasInfix "__VM_DIR__" startHostPs1TemplateText)
        && (lib.hasInfix "switch ('__HOST_KIND__')" startHostPs1TemplateText)
        && (lib.hasInfix "darwin-tart" startHostPs1TemplateText)
        && (lib.hasInfix "darwin-utm" startHostPs1TemplateText)
        && (lib.hasInfix "nixos-libvirt" startHostPs1TemplateText)
        && (lib.hasInfix "__TART_SOFTNET_EXPOSE__" startHostPs1TemplateText)
        && (lib.hasInfix "tart run" startHostPs1TemplateText)
        && (lib.hasInfix "--net-softnet" startHostPs1TemplateText)
        && (lib.hasInfix "--net-softnet-expose" startHostPs1TemplateText)
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
        && (lib.hasInfix "__VM_ID__" stopPosixShTemplateText)
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
        && (lib.hasInfix "__VM_ID__" stopHostPs1TemplateText)
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
        && (lib.hasInfix "s|__VM_ID__|" vm_setup_sh_text)
        && (lib.hasInfix "s|__VM_DISPLAY__|" vm_setup_sh_text)
        && (lib.hasInfix "s|__VM_DIR__|" vm_setup_sh_text)
        && (lib.hasInfix "start-host.ps1" vm_setup_sh_text)
        && (lib.hasInfix "stop-posix.sh" vm_setup_sh_text)
        && (lib.hasInfix "stop-host.ps1" vm_setup_sh_text)
      )
      "vm.sh must render start-host.ps1/stop-posix.sh/stop-host.ps1 via sed token chains that cover all template placeholders";

  # Tart softnet expose must be rendered from manifest portForwards for darwin-tart.
  test_vm_tart_softnet_expose_render_chain =
    assert'
      (
        (lib.hasInfix "s|__TART_SOFTNET_EXPOSE__|" vm_setup_sh_text)
        && (lib.hasInfix "join(\",\")" vm_setup_sh_text)
        && (lib.hasInfix "tart ip" vm_setup_sh_text)
        && (lib.hasInfix "--net-softnet-expose" vm_setup_sh_text)
      )
      "vm.sh must render __TART_SOFTNET_EXPOSE__ from portForwards for darwin-tart and probe macOS guests via tart ip";

  test_vm_start_windows_template_content =
    assert'
      (
        (lib.hasInfix "__QEMU_SYSTEM__" startWindowsTemplateText)
        && (lib.hasInfix "__VM_DISPLAY__" startWindowsTemplateText)
        && (lib.hasInfix "__MACHINE__" startWindowsTemplateText)
        && (lib.hasInfix "__CPU__" startWindowsTemplateText)
        && (lib.hasInfix "__CPUS__" startWindowsTemplateText)
        && (lib.hasInfix "__RAM_BYTES__" startWindowsTemplateText)
        && (lib.hasInfix "__DISK_PATH__" startWindowsTemplateText)
        && (lib.hasInfix "__VGA__" startWindowsTemplateText)
        && (lib.hasInfix "__DISPLAY_BACKEND__" startWindowsTemplateText)
        && (lib.hasInfix "__VIRTIOFS_ARGS__" startWindowsTemplateText)
        && (lib.hasInfix "org.qemu.guest_agent.0" startWindowsTemplateText)
        && (lib.hasInfix "__HOSTFWDS__" startWindowsTemplateText)
        && (lib.hasInfix "chardev pipe" startWindowsTemplateText)
        && (!lib.hasInfix "{{" startWindowsTemplateText)
      )
      "src/vms/templates/start-windows.ps1 must contain all expected __TOKEN__ placeholders and QEMU arguments, with no {{TOKEN}} style";

  test_vm_start_windows_host_template_content =
    assert'
      (
        (lib.hasInfix "__QEMU_SYSTEM__" startWindowsHostTemplateText)
        && (lib.hasInfix "__VM_ID__" startWindowsHostTemplateText)
        && (lib.hasInfix "__VM_DISPLAY__" startWindowsHostTemplateText)
        && (lib.hasInfix "__MACHINE__" startWindowsHostTemplateText)
        && (lib.hasInfix "__CPU__" startWindowsHostTemplateText)
        && (lib.hasInfix "__CPUS__" startWindowsHostTemplateText)
        && (lib.hasInfix "__RAM_BYTES__" startWindowsHostTemplateText)
        && (lib.hasInfix "__DISK_PATH__" startWindowsHostTemplateText)
        && (lib.hasInfix "__VGA__" startWindowsHostTemplateText)
        && (lib.hasInfix "__DISPLAY_BACKEND__" startWindowsHostTemplateText)
        && (lib.hasInfix "org.qemu.guest_agent.0" startWindowsHostTemplateText)
        && (lib.hasInfix "__HOSTFWDS__" startWindowsHostTemplateText)
        && (lib.hasInfix "chardev pipe" startWindowsHostTemplateText)
        && (lib.hasInfix "set -eu" startWindowsHostTemplateText)
        && (!lib.hasInfix "{{" startWindowsHostTemplateText)
      )
      "src/vms/templates/start-windows-host.sh must contain all expected __TOKEN__ placeholders and QEMU arguments, with no {{TOKEN}} style";

  # Windows start-script render chains must inject the __HOSTFWDS__ token from
  # the manifest portForwards on both platforms.
  test_vm_hostfwds_render_chain =
    assert'
      (
        (lib.hasInfix "s|__HOSTFWDS__|" vm_setup_sh_text)
        && (lib.hasInfix ".Replace('__HOSTFWDS__'" windows_vm_setup_ps1_text)
      )
      "vm.sh and Invoke-VMSetup.ps1 must render __HOSTFWDS__ into Windows start scripts from the manifest portForwards";

  test_vm_directory_readme_generation =
    assert'
      (
        (lib.hasInfix "write_vm_directory_readme" vm_setup_sh_text)
        && (lib.hasInfix "wrote VM directory guide" vm_setup_sh_text)
        && (lib.hasInfix "TEMPLATES_DIR/README.md" vm_setup_sh_text)
        && (lib.hasInfix "s|__VM_DIR_DISPLAY__|" vm_setup_sh_text)
        && (lib.hasInfix "__VM_DIR_DISPLAY__" readmeTemplateText)
        && (lib.hasInfix "## Start commands" readmeTemplateText)
        && (lib.hasInfix "## Troubleshooting" readmeTemplateText)
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
        && (lib.hasInfix "## Troubleshooting" readmeTemplateText)
        && (lib.hasInfix "UTM bundle" readmeTemplateText)
      )
      "Invoke-VMSetup.ps1 must write %USERPROFILE%\\virtual machines\\README.md using the cross-host README template with placeholder substitution";
  test_vm_setup_generates_helper_scripts = assert' (lib.hasInfix "write_start_script" vm_setup_sh_text) "VM setup flows must generate discoverable start helper scripts";

  test_vm_enabled_policy_wiring = assert' (
    (lib.hasInfix "\"enabled\"" vms_json_text)
    && (lib.hasInfix ".VMs[$_i].enabled" vm_setup_sh_text)
    && (lib.hasInfix "disabled in manifest; skipping" vm_setup_sh_text)
    && (lib.hasInfix "function Test-VMEnabled" windows_vm_setup_ps1_text)
    && (lib.hasInfix "$Vm.enabled -isnot [bool]" windows_vm_setup_ps1_text)
    && (lib.hasInfix "enabledVms = builtins.filter (" macbook_vms_nix_text)
    && (lib.hasInfix "enabledVms = builtins.filter (" (builtins.readFile ../../src/hosts/NixOS/vms.nix))
  ) "VM enable/disable policy must be wired in manifest, setup scripts, and host template generation";

  # The Android GSI drive must be rendered only when the Android group's
  # gsiUrl is set; a revert to unconditional GSI emission must fail. The
  # userdata drive stays attached unconditionally.  Bundle ImageNames are
  # guest-agnostic natural-language disk names (user data.qcow2 / GSI
  # disk.qcow2), never manifest leaf names or hardcoded android-* literals.
  test_macbook_android_gsi_conditional =
    assert'
      (
        (lib.hasInfix "vm.Android.gsiUrl != null" macbook_vms_nix_text)
        && (lib.hasInfix "<string>GSI disk.qcow2</string>" macbook_vms_nix_text)
        && (lib.hasInfix "<string>user data.qcow2</string>" macbook_vms_nix_text)
        && !(lib.hasInfix "\${vm.Android.gsiImage}" macbook_vms_nix_text)
        && !(lib.hasInfix "\${vm.Android.userdataImage}" macbook_vms_nix_text)
      )
      "src/hosts/MacBook/vms.nix must render the GSI drive only when vm.Android.gsiUrl is non-null while keeping the userdata drive (user data.qcow2) attached unconditionally";

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

  # NixOS libvirt domain XML must render manifest portForwards via passt user
  # networking (<range start= host-to-guest mapping), not legacy libvirt NAT or
  # <host port= forwarding syntax.
  test_nixos_port_forwards_from_manifest =
    assert'
      (
        (lib.hasInfix "vm.portForwards" nixos_vms_nix_text)
        && (lib.hasInfix "passt" nixos_vms_nix_text)
        && (lib.hasInfix "__VM_NETWORK_INTERFACE__" nixos_domain_xml_text)
        && (lib.hasInfix "<range start=" nixos_vms_nix_text)
        && !(lib.hasInfix "<host port=" nixos_vms_nix_text)
      )
      "src/hosts/NixOS/vms.nix must render all manifest portForwards via passt portForwardRanges into __VM_NETWORK_INTERFACE__ using <range start= host-to-guest mapping";

  # NixOS libvirt domain XML must attach the GSI disk only when the Android
  # group's gsiUrl is set, mirroring the MacBook UTM template.  The image name
  # comes from the manifest Android group, never a hardcoded android-* literal.
  test_nixos_android_gsi_conditional = assert' (
    (lib.hasInfix "vm.Android.gsiUrl != null" nixos_vms_nix_text)
    && (lib.hasInfix "src/Android/\${vm.Android.gsiImage}" nixos_vms_nix_text)
  ) "src/hosts/NixOS/vms.nix must render the GSI disk only when vm.Android.gsiUrl is non-null";

  # NixOS Android system disk must be the writable data/<id> (system).qcow2
  # overlay over src/Android/system image.qcow2 (src/ stays pristine); the
  # userdata disk is the canonical data/<id>.qcow2; the GSI payload stays
  # under src/Android/ read-only.  Bare ${vmDir}/android-* paths would break
  # the cross-host src/data layout.
  test_nixos_android_disk_paths =
    assert'
      (
        (lib.hasInfix "\${vmDir}/data/\${vm.id} (system).qcow2" nixos_vms_nix_text)
        && (lib.hasInfix "\${vmDir}/data/\${vm.id}.qcow2" nixos_vms_nix_text)
        && !(lib.hasInfix "\${vmDir}/android-system.qcow2" nixos_vms_nix_text)
        && !(lib.hasInfix "\${vmDir}/android-userdata.qcow2" nixos_vms_nix_text)
      )
      "src/hosts/NixOS/vms.nix must attach the Android system disk as the writable data/<id> (system).qcow2 overlay and userdata as data/<id>.qcow2, never at the bare VM directory root";

  test_macbook_tart_storage_link =
    assert'
      (
        (lib.hasInfix "ensure_tart_vm_dir" vm_setup_sh_text)
        && (lib.hasInfix "_etd_target=\"\$VM_DIR/tart\"" vm_setup_sh_text)
        && (lib.hasInfix "linked tart storage" vm_setup_sh_text)
        && !(lib.hasInfix "rsync" vm_setup_sh_text)
      )
      "scripts/vm.sh must link ~/.tart -> ~/virtual machines/tart without migrating existing stores in-script";

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
    test_size_parser_accepts
    test_size_parser_rejects
    test_size_ceil_mib
    test_size_grammar_parity_across_implementations
    test_size_schema_pattern
    test_manifest_sizes_are_suffixed_strings
    test_manifest_sizes_match_pattern
    test_manifest_size_values_are_canonical
    test_vm_status_display_parses_suffixed_ram
    test_macos_packer_ceil_units
    test_min_image_size_floor_wiring
    test_cpu_counts
    test_vm_names
    test_vm_types
    test_share_dev_dir_types
    test_enabled_types
    test_vm_id_nonempty_and_filesystem_safe
    test_vm_id_uniqueness
    test_port_forwards_shape
    test_port_forwards_host_range
    test_port_forwards_host_unique
    test_port_forwards_guest_semantics
    test_hostname_nonempty
    test_hostname_equals_name
    test_min_image_size_pattern
    test_mac_address_prefix_nonempty
    test_group_key_equals_type
    test_group_inner_props_required
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
    test_vm_sync_subcommand_wired
    test_vm_android_config_subcommand_wired
    test_android_tools_provisioned_all_hosts
    test_vm_setup_calls_sync_phase
    test_vm_sync_utm_includes_registration
    test_vm_setup_removes_utm_screenshot
    test_apply_vm_sync_default_on
    test_guest_nix_nonempty
    test_nixos_guest_qemu_guest_enabled
    test_nixos_guest_openssh_enabled
    test_nixos_guest_nucleus_rebuild_service
    test_nixos_guest_ssh_authorized_keys
    test_vm_guest_ssh_public_key_manifest
    test_vm_guest_ssh_public_key_resolver_wired
    test_vm_android_recovery_filename_parity
    test_tart_in_homebrew
    test_macbook_linux_builder_enabled
    test_macbook_linux_builder_machines_file
    test_macbook_linux_builder_uses_ssh_protocol
    test_macbook_linux_builder_user_ssh_key_copy
    test_macbook_linux_builder_ssh_match_blocks
    test_macbook_builders_machines
    test_macos_packer_exit_check
    test_nixos_generators_output_link_handling
    test_nixos_guest_btrfs_format_paths
    test_nixos_host_disks_btrfs_root
    test_nixos_btrfs_subvolume_layout
    test_nixos_guest_documents_btrfs_formats
    test_nixos_packer_btrfs_root
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
    test_utm_base_overlay_provisioning
    test_utm_android_uses_shared_images
    test_android_userdata_hard_link_no_legacy_paths
    test_libvirt_android_userdata_canonical_path
    test_android_build_strips_wc_padding
    test_android_build_honors_manifest_disk_size
    test_libvirt_runtime_validation_parity
    test_windows_iso_mido_patch_file_exists
    test_windows_iso_mido_runtime_patch_support
    test_windows_iso_mido_patch_failure_is_fatal
    test_macbook_utm_windows_arch_override
    test_macbook_utm_schema_keys
    test_macbook_utm_plist_correctness
    test_macbook_utm_emulated_network_for_port_forward
    test_macbook_utm_port_forwards_from_manifest
    test_macbook_utm_display_card_validity
    test_macbook_utm_firmware_contract
    test_macbook_utm_data_dir_disk_path
    test_macbook_utm_uses_direct_bundle_open
    test_macbook_utm_refreshes_existing_bundle
    test_macbook_utm_stale_template_guard
    test_vm_readme_template_content
    test_vm_start_posix_template_content
    test_vm_start_windows_template_content
    test_vm_start_windows_host_template_content
    test_vm_start_host_ps1_template_content
    test_vm_stop_posix_template_content
    test_vm_stop_host_ps1_template_content
    test_vm_host_templates_render_chains
    test_vm_tart_softnet_expose_render_chain
    test_vm_directory_readme_generation
    test_windows_vm_directory_readme_generation
    test_vm_setup_generates_helper_scripts
    test_macbook_tart_storage_link
    test_vm_enabled_policy_wiring
    test_macbook_android_gsi_conditional
    test_utm_android_drives_inside_drive_array
    test_nixos_port_forwards_from_manifest
    test_nixos_android_gsi_conditional
    test_nixos_android_disk_paths
    test_windows_iso_fido_nonwindows_fallback
    test_android_gsi_url_type
    test_android_gsi_url_only_on_android
    test_enabled_vm_not_orphaned
    test_vm_gc_preserves_disabled_entries_by_default
    test_vm_gc_disabled_option_pair
    test_vm_gc_data_skips_data_by_default
    test_vm_gc_data_option_pair
    test_windows_vm_gc_data_option_pair
    test_windows_vm_gc_preserves_disabled_entries_by_default
    test_nixos_guest_threads_username_arg
    test_nixos_guest_standalone_eval_overrides
    test_macbook_utm_required_key_guard
    test_android_sound_disabled
    test_macbook_utm_sound_token
    test_macbook_utm_vm_sound_mapping
    test_android_start_script_tokens
    test_vm_write_start_script_android_sed_chain
    test_vm_hostfwds_render_chain
    test_vm_guest_hostname_env_export
    test_nixos_packer_guest_hostname_var
    test_windows_autounattend_guest_hostname_token
    test_macbook_mac_address_uses_manifest_prefix
    test_identity_uuid_vectors
    test_identity_mac_vectors
    test_macbook_identity_from_shared_lib
    test_vm_resize_grow_only_and_guard
    test_vm_resize_cli_subcommand
    test_vm_resize_windows_twin
    test_vm_pack_cli_subcommand
    test_vm_pack_removal_set
    test_vm_pack_next_steps
    test_vm_pack_windows_twin
    test_vm_unpack_cli_subcommand
    test_vm_unpack_enabled_gate
    test_vm_unpack_descriptor_first
    test_vm_unpack_windows_twin
    test_vm_build_system_cli_subcommand
    test_vm_build_system_windows_twin
    test_vm_inject_cli_subcommand
    test_vm_inject_windows_twin
    test_vm_inject_dispatches_by_type
    test_vm_gc_keep_set_preserves_manifest_images
    test_vm_gc_orphan_descriptors_removed
    test_vm_gc_marker_expected_set_semantics
    test_windows_vm_gc_keep_set
    test_vm_fingerprint_marker_split
    test_windows_vm_fingerprint_marker_split
    test_android_build_relink_refresh
    test_windows_base_overlay_parity
    test_windows_qemu_ensure_base_and_overlay
    test_vm_provision_one_orchestrator
    test_vm_ensure_data_disk_preservation
    test_vm_provision_android_marker_adoption_only
    test_windows_vm_data_disk_preservation
    test_vm_android_build_skip_if_exists
    test_vm_ensure_android_system_overlay
    test_windows_qemu_android_system_overlay
    test_start_android_system_overlay_data_dir
    test_android_system_overlay_render_leaves
    test_android_nvram_render_leaves
    test_android_nvram_macos_adoption_and_windows_seed
    test_utm_bundle_hard_link_only
  ];

in
{
  inherit
    test_required_fields
    test_disk_sizes
    test_ram_sizes
    test_size_parser_accepts
    test_size_parser_rejects
    test_size_ceil_mib
    test_size_grammar_parity_across_implementations
    test_size_schema_pattern
    test_manifest_sizes_are_suffixed_strings
    test_manifest_sizes_match_pattern
    test_manifest_size_values_are_canonical
    test_vm_status_display_parses_suffixed_ram
    test_macos_packer_ceil_units
    test_min_image_size_floor_wiring
    test_cpu_counts
    test_vm_names
    test_vm_types
    test_share_dev_dir_types
    test_enabled_types
    test_vm_id_nonempty_and_filesystem_safe
    test_vm_id_uniqueness
    test_port_forwards_shape
    test_port_forwards_host_range
    test_port_forwards_host_unique
    test_port_forwards_guest_semantics
    test_hostname_nonempty
    test_hostname_equals_name
    test_min_image_size_pattern
    test_mac_address_prefix_nonempty
    test_group_key_equals_type
    test_group_inner_props_required
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
    test_vm_sync_subcommand_wired
    test_vm_android_config_subcommand_wired
    test_android_tools_provisioned_all_hosts
    test_vm_setup_calls_sync_phase
    test_vm_sync_utm_includes_registration
    test_vm_setup_removes_utm_screenshot
    test_apply_vm_sync_default_on
    test_guest_nix_nonempty
    test_nixos_guest_qemu_guest_enabled
    test_nixos_guest_openssh_enabled
    test_nixos_guest_nucleus_rebuild_service
    test_nixos_guest_ssh_authorized_keys
    test_vm_guest_ssh_public_key_manifest
    test_vm_guest_ssh_public_key_resolver_wired
    test_vm_android_recovery_filename_parity
    test_tart_in_homebrew
    test_macbook_linux_builder_enabled
    test_macbook_linux_builder_machines_file
    test_macbook_linux_builder_uses_ssh_protocol
    test_macbook_linux_builder_user_ssh_key_copy
    test_macbook_linux_builder_ssh_match_blocks
    test_macbook_builders_machines
    test_macos_packer_exit_check
    test_nixos_generators_output_link_handling
    test_nixos_guest_btrfs_format_paths
    test_nixos_host_disks_btrfs_root
    test_nixos_btrfs_subvolume_layout
    test_nixos_guest_documents_btrfs_formats
    test_nixos_packer_btrfs_root
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
    test_utm_base_overlay_provisioning
    test_utm_android_uses_shared_images
    test_android_userdata_hard_link_no_legacy_paths
    test_libvirt_android_userdata_canonical_path
    test_android_build_strips_wc_padding
    test_android_build_honors_manifest_disk_size
    test_libvirt_runtime_validation_parity
    test_windows_iso_mido_patch_file_exists
    test_windows_iso_mido_runtime_patch_support
    test_windows_iso_mido_patch_failure_is_fatal
    test_macbook_utm_windows_arch_override
    test_macbook_utm_schema_keys
    test_macbook_utm_plist_correctness
    test_macbook_utm_emulated_network_for_port_forward
    test_macbook_utm_port_forwards_from_manifest
    test_macbook_utm_display_card_validity
    test_macbook_utm_firmware_contract
    test_macbook_utm_data_dir_disk_path
    test_macbook_utm_uses_direct_bundle_open
    test_macbook_utm_refreshes_existing_bundle
    test_macbook_utm_stale_template_guard
    test_vm_readme_template_content
    test_vm_start_posix_template_content
    test_vm_start_windows_template_content
    test_vm_start_windows_host_template_content
    test_vm_start_host_ps1_template_content
    test_vm_stop_posix_template_content
    test_vm_stop_host_ps1_template_content
    test_vm_host_templates_render_chains
    test_vm_tart_softnet_expose_render_chain
    test_vm_directory_readme_generation
    test_windows_vm_directory_readme_generation
    test_vm_setup_generates_helper_scripts
    test_macbook_tart_storage_link
    test_vm_enabled_policy_wiring
    test_macbook_android_gsi_conditional
    test_utm_android_drives_inside_drive_array
    test_nixos_port_forwards_from_manifest
    test_nixos_android_gsi_conditional
    test_nixos_android_disk_paths
    test_windows_iso_fido_nonwindows_fallback
    test_android_gsi_url_type
    test_android_gsi_url_only_on_android
    test_enabled_vm_not_orphaned
    test_vm_gc_preserves_disabled_entries_by_default
    test_vm_gc_disabled_option_pair
    test_vm_gc_data_skips_data_by_default
    test_vm_gc_data_option_pair
    test_windows_vm_gc_data_option_pair
    test_windows_vm_gc_preserves_disabled_entries_by_default
    test_nixos_guest_threads_username_arg
    test_nixos_guest_standalone_eval_overrides
    test_macbook_utm_required_key_guard
    test_android_sound_disabled
    test_macbook_utm_sound_token
    test_macbook_utm_vm_sound_mapping
    test_android_start_script_tokens
    test_vm_write_start_script_android_sed_chain
    test_vm_hostfwds_render_chain
    test_vm_guest_hostname_env_export
    test_nixos_packer_guest_hostname_var
    test_windows_autounattend_guest_hostname_token
    test_macbook_mac_address_uses_manifest_prefix
    test_identity_uuid_vectors
    test_identity_mac_vectors
    test_macbook_identity_from_shared_lib
    test_vm_resize_grow_only_and_guard
    test_vm_resize_cli_subcommand
    test_vm_resize_windows_twin
    test_vm_pack_cli_subcommand
    test_vm_pack_removal_set
    test_vm_pack_next_steps
    test_vm_pack_windows_twin
    test_vm_unpack_cli_subcommand
    test_vm_unpack_enabled_gate
    test_vm_unpack_descriptor_first
    test_vm_unpack_windows_twin
    test_vm_build_system_cli_subcommand
    test_vm_build_system_windows_twin
    test_vm_inject_cli_subcommand
    test_vm_inject_windows_twin
    test_vm_inject_dispatches_by_type
    test_vm_gc_keep_set_preserves_manifest_images
    test_vm_gc_orphan_descriptors_removed
    test_vm_gc_marker_expected_set_semantics
    test_windows_vm_gc_keep_set
    test_vm_fingerprint_marker_split
    test_windows_vm_fingerprint_marker_split
    test_android_build_relink_refresh
    test_windows_base_overlay_parity
    test_windows_qemu_ensure_base_and_overlay
    test_vm_provision_one_orchestrator
    test_vm_ensure_data_disk_preservation
    test_vm_provision_android_marker_adoption_only
    test_windows_vm_data_disk_preservation
    test_vm_android_build_skip_if_exists
    test_vm_ensure_android_system_overlay
    test_windows_qemu_android_system_overlay
    test_start_android_system_overlay_data_dir
    test_android_system_overlay_render_leaves
    test_utm_bundle_hard_link_only
    ;

  summary = builtins.deepSeq all_tests "vm-setup-tests: all tests passed";
}
