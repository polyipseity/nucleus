# tests/integration/strip-metadata-tests.nix — Verify cross-platform parity for metadata stripping.

let
  lib = import <nixpkgs/lib>;
  macAutomatorWorkflowsText = builtins.readFile ../../src/hosts/MacBook/services/automator-workflows/default.nix;
  nixosServicesText = builtins.readFile ../../src/hosts/NixOS/services.nix;
  windowsDscText = builtins.readFile ../../src/hosts/Windows/user/context-strip-metadata.dsc.yml;
  utilsShText = builtins.readFile ../../scripts/utils.sh;
  utilsPs1Text = builtins.readFile ../../scripts/utils.ps1;

  inherit (import ../lib.nix) assert';

  macWorkflowsDir = ../../src/hosts/MacBook/services/automator-workflows;
  macWorkflowPlist = builtins.readFile (
    builtins.toPath (toString macWorkflowsDir + "/strip metadata.workflow/Contents/Info.plist")
  );

  # === macOS tests ===

  test_single_strip_metadata_workflow_exists = assert' (
    lib.hasInfix "strip metadata.workflow" macAutomatorWorkflowsText
    && lib.hasInfix "com.nucleus.StripMetadata" macAutomatorWorkflowsText
    && !lib.hasInfix "strip metadata - excel.workflow" macAutomatorWorkflowsText
    && !lib.hasInfix "strip metadata - word.workflow" macAutomatorWorkflowsText
    && !lib.hasInfix "strip metadata - powerpoint.workflow" macAutomatorWorkflowsText
  ) "macOS automator-workflows.nix must define exactly 1 strip-metadata workflow (not 6 variants)";

  test_strip_metadata_uses_public_item = assert' (
    lib.hasInfix "public.item" macWorkflowPlist
    && !lib.hasInfix "org.openxmlformats" macWorkflowPlist
    && !lib.hasInfix "com.microsoft" macWorkflowPlist
  ) "Unified strip-metadata Info.plist must use public.item UTI (not per-format UTIs)";

  # === NixOS tests ===

  test_nixos_has_strip_metadata = assert' (
    lib.hasInfix "strip metadata" nixosServicesText
    && lib.hasInfix "strip-metadata-nautilus" nixosServicesText
  ) "NixOS services.nix must define strip-metadata Nautilus script";

  # === Windows tests ===

  test_windows_has_strip_metadata_label = assert' (lib.hasInfix "strip metadata" windowsDscText) "Windows DSC must use the 'strip metadata' label";

  # === Notification parity tests ===

  test_posix_has_notify_helper = assert' (
    lib.hasInfix "_notify" utilsShText
    && lib.hasInfix "osascript" utilsShText
    && lib.hasInfix "notify-send" utilsShText
  ) "POSIX utils.sh must define _notify helper with osascript + notify-send";

  test_windows_has_notification = assert' (lib.hasInfix "Show-NucleusNotification" utilsPs1Text) "Windows utils.ps1 must call Show-NucleusNotification in strip-metadata path";

  allTests = [
    test_single_strip_metadata_workflow_exists
    test_strip_metadata_uses_public_item
    test_nixos_has_strip_metadata
    test_windows_has_strip_metadata_label
    test_posix_has_notify_helper
    test_windows_has_notification
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "strip-metadata cross-platform parity tests passed";
}
