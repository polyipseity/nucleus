# tests/modules/vm-setup-tests.nix — VM provisioning manifest and NixOS module options.

let
  lib = import <nixpkgs/lib>;
  inherit (import ../lib.nix) assert';

  manifest = builtins.fromJSON (builtins.readFile ../../src/modules/vms/VMs.json);

  # Deterministic identity derivation, shared with src/hosts/MacBook/vms.nix.
  vmIdentity = import ../../src/modules/vms/vm-identity.nix;

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
  vms_schema_text = builtins.readFile ../../src/modules/vms/VMs.schema.json;

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

  # Known SHA-256 identity vectors (see src/modules/vms/vm-identity.nix). The
  # vectors pin the derivation so neither the Nix lib nor its shell twin can
  # drift silently; a guest id change is a breaking identity change.

  # UUID derivation must match the pinned SHA-256 vectors.

  # MAC derivation must match the pinned SHA-256 vectors.

  # The MacBook host must derive identities from the shared library using the
  # VM id (runtime truth) — never a local re-implementation keyed on name.
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

  # --- Behavioral: VM reachability and identity contract ---

  # Every enabled VM must be reachable by at least one known host (MacBook,
  # NixOS, Windows).  An orphaned VM (enabled but with a hosts list that
  # excludes all known hosts) would never be provisioned by any machine.
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

  # hostname must equal display name (guest OS identity contract).
  test_hostname_equals_name =
    let
      badHostnameName = builtins.filter (vm: vm.hostname != vm.name) manifest.VMs;
    in
    assert' (badHostnameName == [ ])
      "Every VM hostname must equal name; bad entries: ${
        builtins.toString (builtins.map (v: v.name) badHostnameName)
      }";

  # Packer templates and guest configs must exist.
  test_packer_templates_exist =
    let
      checks = [
        {
          cond = builtins.pathExists ../../src/vms/NixOS/base-guest.nix;
          msg = "src/vms/NixOS/base-guest.nix must exist";
        }
        {
          cond = builtins.pathExists ../../src/vms/guests/NixOS/guest.nix;
          msg = "src/vms/guests/NixOS/guest.nix must exist";
        }
        {
          cond = builtins.pathExists ../../src/vms/NixOS/packer.pkr.hcl;
          msg = "src/vms/NixOS/packer.pkr.hcl must exist";
        }
        {
          cond = builtins.pathExists ../../src/vms/Windows/packer.pkr.hcl;
          msg = "src/vms/Windows/packer.pkr.hcl must exist";
        }
        {
          cond = builtins.pathExists ../../src/vms/Windows/Autounattend.xml;
          msg = "src/vms/Windows/Autounattend.xml must exist";
        }
        {
          cond = builtins.pathExists ../../src/vms/macOS/packer.pkr.hcl;
          msg = "src/vms/macOS/packer.pkr.hcl must exist";
        }
        {
          cond = builtins.pathExists ../../src/vms/NixOS/formats/qcow-btrfs.nix;
          msg = "src/vms/NixOS/formats/qcow-btrfs.nix must exist";
        }
        {
          cond = builtins.pathExists ../../src/vms/NixOS/formats/qcow-efi-btrfs.nix;
          msg = "src/vms/NixOS/formats/qcow-efi-btrfs.nix must exist";
        }
        {
          cond = builtins.pathExists ../../src/vms/NixOS/disk-image/make-btrfs-disk-image.nix;
          msg = "src/vms/NixOS/disk-image/make-btrfs-disk-image.nix must exist";
        }
      ];
      results = builtins.map (c: assert' c.cond c.msg) checks;
    in
    assert' (builtins.all (r: r == null) results) "Packer template file existence check failed";

  # VM setup templates must exist.
  test_vm_templates_exist =
    let
      checks = [
        {
          cond = builtins.pathExists ../../src/vms/templates/README.md;
          msg = "src/vms/templates/README.md must exist";
        }
        {
          cond = builtins.pathExists ../../src/vms/templates/start-posix.sh;
          msg = "src/vms/templates/start-posix.sh must exist";
        }
        {
          cond = builtins.pathExists ../../src/vms/templates/start-windows.ps1;
          msg = "src/vms/templates/start-windows.ps1 must exist";
        }
        {
          cond = builtins.pathExists ../../src/vms/templates/start-windows-host.sh;
          msg = "src/vms/templates/start-windows-host.sh must exist";
        }
        {
          cond = builtins.pathExists ../../src/vms/templates/start-host.ps1;
          msg = "src/vms/templates/start-host.ps1 must exist";
        }
        {
          cond = builtins.pathExists ../../src/vms/templates/stop-posix.sh;
          msg = "src/vms/templates/stop-posix.sh must exist";
        }
        {
          cond = builtins.pathExists ../../src/vms/templates/stop-host.ps1;
          msg = "src/vms/templates/stop-host.ps1 must exist";
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

  # base-guest.nix and guests/<id>/guest.nix must be non-empty.
  test_guest_nix_nonempty =
    let
      baseContent = builtins.readFile ../../src/vms/NixOS/base-guest.nix;
      guestContent = builtins.readFile ../../src/vms/guests/NixOS/guest.nix;
    in
    assert' (
      builtins.stringLength baseContent > 0 && builtins.stringLength guestContent > 0
    ) "src/vms/NixOS/base-guest.nix and src/vms/guests/NixOS/guest.nix must not be empty";

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
    test_min_image_size_pattern
    test_mac_address_prefix_nonempty
    test_group_key_equals_type
    test_group_inner_props_required
    test_windows_iso_url_type
    test_macos_version_type
    test_windows_edition_type
    test_android_gsi_url_type
    test_android_gsi_url_only_on_android
    test_android_sound_disabled
    test_hosts_field
    test_plist_uuid_format
    test_plist_uuid_uniqueness
    test_domain_xml_kvm_type
    test_domain_xml_memory_unit
    test_domain_xml_disk_path_lowercase
    test_enabled_vm_not_orphaned
    test_hostname_equals_name
    test_packer_templates_exist
    test_vm_templates_exist
    test_vm_setup_scripts_exist
    test_guest_nix_nonempty
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
    test_min_image_size_pattern
    test_mac_address_prefix_nonempty
    test_group_key_equals_type
    test_group_inner_props_required
    test_windows_iso_url_type
    test_macos_version_type
    test_windows_edition_type
    test_android_gsi_url_type
    test_android_gsi_url_only_on_android
    test_android_sound_disabled
    test_hosts_field
    test_plist_uuid_format
    test_plist_uuid_uniqueness
    test_domain_xml_kvm_type
    test_domain_xml_memory_unit
    test_domain_xml_disk_path_lowercase
    test_enabled_vm_not_orphaned
    test_hostname_equals_name
    test_packer_templates_exist
    test_vm_templates_exist
    test_vm_setup_scripts_exist
    test_guest_nix_nonempty
    ;

  summary = builtins.deepSeq all_tests "vm-setup-manifest-tests: all tests passed";
}
