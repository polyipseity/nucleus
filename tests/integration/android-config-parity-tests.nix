# tests/integration/android-config-parity-tests.nix — Cross-host android-config parity wiring.

let
  lib = import <nixpkgs/lib>;
  inherit (import ../lib.nix) assert';

  vmSetupShText = builtins.readFile ../../scripts/vm.sh;
  vmPs1Text = builtins.readFile ../../scripts/vm.ps1;
  androidConfigShText = builtins.readFile ../../src/scripts/vms/android-config.sh;
  androidMagiskShText = builtins.readFile ../../src/scripts/vms/android-magisk.sh;
  invokeAndroidConfigPs1Text = builtins.readFile ../../src/hosts/Windows/modules/system/Invoke-AndroidConfig.ps1;
  coreNixText = builtins.readFile ../../src/modules/core.nix;
  flakeNixText = builtins.readFile ../../src/flake.nix;
  windowsPackagesDscText = builtins.readFile ../../src/hosts/Windows/system/packages.dsc.yml;
  shellProfileText = builtins.readFile ../../src/scripts/shell/profile.ps1;
  macManualText = builtins.readFile ../../src/hosts/MacBook/MANUAL.md;
  nixosManualText = builtins.readFile ../../src/hosts/NixOS/MANUAL.md;
  windowsManualText = builtins.readFile ../../src/hosts/Windows/MANUAL.md;

  test_windows_android_config_native = assert' (
    (lib.hasInfix "Invoke-AndroidConfig" vmPs1Text)
    && (lib.hasInfix "Invoke-AndroidConfig.ps1" vmPs1Text)
    && (lib.hasInfix "VMAndroid.ps1" vmPs1Text)
    && !(lib.hasInfix "& nucleus-vm android-config" vmPs1Text)
    && !(lib.hasInfix "vm.sh android-config" vmPs1Text)
  ) "vm.ps1 must use native Invoke-AndroidConfig without bash or nucleus-vm recursion";

  test_android_config_flags_paired = assert' (
    builtins.all (flag: lib.hasInfix flag vmSetupShText) [
      "--gapps"
      "--adb-keys"
      "--magisk"
      "--root"
      "--fake-wifi"
      "--fake-wifi-revert"
    ]
    && builtins.all (flag: lib.hasInfix flag invokeAndroidConfigPs1Text) [
      "--gapps"
      "--adb-keys"
      "--magisk"
      "--root"
      "--fake-wifi"
      "--fake-wifi-revert"
    ]
  ) "android-config flags must appear in POSIX and Windows implementations";

  test_android_tools_provisioned = assert' (
    (lib.hasInfix "pkgs.android-tools" coreNixText)
    && (lib.hasInfix "pkgs.android-tools" flakeNixText)
    && (lib.hasInfix "Google.PlatformTools" windowsPackagesDscText)
  ) "adb/fastboot must be provisioned on POSIX (core.nix + flake) and Windows (PlatformTools)";

  test_windows_profile_no_sh_scripts = assert' (
    !(lib.hasInfix "Invoke-NucleusRepoScript 'scripts\\check-sh.sh'" shellProfileText)
    && (lib.hasInfix "Invoke-NucleusRepoScript 'scripts\\check-sh.ps1'" shellProfileText)
  ) "Windows profile.ps1 must not invoke .sh scripts for nucleus-check-sh";

  test_manuals_document_android_config = assert' (builtins.all
    (
      text:
      (lib.hasInfix "nucleus-vm android-config Android" text)
      && (lib.hasInfix "nucleus-vm reset Android" text)
    )
    [
      macManualText
      nixosManualText
      windowsManualText
    ]
  ) "All host MANUAL.md files must document android-config and reset workflow";

  test_posix_android_config_wired = assert' (
    (lib.hasInfix "do_android_config" vmSetupShText)
    && (lib.hasInfix "android-config.sh" vmSetupShText)
    && (lib.hasInfix "vm_android_config_print_manual" androidConfigShText)
  ) "POSIX vm.sh must wire android-config.sh";

  test_no_adb_root_in_android_config_sources = assert' (
    !(lib.hasInfix "adb root" androidConfigShText)
    && !(lib.hasInfix "adb root" androidMagiskShText)
    && !(lib.hasInfix "adb_ensure_root" androidConfigShText)
    && !(lib.hasInfix "adb_ensure_root" androidMagiskShText)
    && !(lib.hasInfix "recovery_prepare_adb" androidConfigShText)
    && !(lib.hasInfix "GuestHasAdbRoot" invokeAndroidConfigPs1Text)
    && !(lib.hasInfix "AdbEnsureRoot" invokeAndroidConfigPs1Text)
    && !(lib.hasInfix "RecoveryPrepareAdb" invokeAndroidConfigPs1Text)
    && !(lib.hasInfix "MagiskpolicyForAdbRoot" invokeAndroidConfigPs1Text)
  ) "android-config sources must not reference adb root helpers";

  allTests = [
    test_windows_android_config_native
    test_android_config_flags_paired
    test_android_tools_provisioned
    test_windows_profile_no_sh_scripts
    test_manuals_document_android_config
    test_posix_android_config_wired
    test_no_adb_root_in_android_config_sources
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "android-config cross-host parity tests passed";
}
