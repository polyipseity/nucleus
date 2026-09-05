# tests/integration/strip-metadata-tests.nix — Verify cross-platform parity for metadata stripping.

let
  lib = import <nixpkgs/lib>;
  macAutomatorWorkflowsText = builtins.readFile ../../src/hosts/MacBook/services/automator-workflows.nix;
  nixosServicesText = builtins.readFile ../../src/hosts/NixOS/services.nix;
  windowsDscText = builtins.readFile ../../src/hosts/Windows/user/context-strip-metadata.dsc.yml;
  nautilusScriptText = builtins.readFile ../../src/scripts/integrations/configure-file-manager-strip-metadata.sh;
  plasmaDesktopText = builtins.readFile ../../src/users/default/plasma/desktop/nucleus-strip-metadata.desktop;
  utilsShText = builtins.readFile ../../scripts/utils.sh;

  inherit (import ../lib.nix) assert';

  # Check that a context menu entry invokes strip-metadata.
  hasStripMetadataCommand = text: lib.hasInfix "strip-metadata" text;

  macWorkflowsDir = ../../src/hosts/MacBook/services/automator-workflows;
  macWorkflowPlist = builtins.readFile (
    builtins.toPath (toString macWorkflowsDir + "/strip metadata.workflow/Contents/Info.plist")
  );
  macWorkflowWflow = builtins.readFile (
    builtins.toPath (toString macWorkflowsDir + "/strip metadata.workflow/Contents/document.wflow")
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

  test_macos_workflow_ordering = assert' (
    let
      posOpenManual = builtins.stringLength (
        builtins.head (builtins.split "\"open nucleus manual.workflow\"" macAutomatorWorkflowsText)
      );
      posStripMeta = builtins.stringLength (
        builtins.head (builtins.split "\"strip metadata.workflow\"" macAutomatorWorkflowsText)
      );
      posOptDefault = builtins.stringLength (
        builtins.head (builtins.split "\"optimize PDF - default.workflow\"" macAutomatorWorkflowsText)
      );
    in
    posOpenManual < posStripMeta && posStripMeta < posOptDefault
  ) "macOS strip-metadata workflow must be between 'open nucleus manual' and 'optimize PDF' blocks";

  test_macos_workflow_has_strip_metadata_command = assert' (hasStripMetadataCommand macWorkflowWflow) "macOS strip-metadata document.wflow must invoke strip-metadata";

  # === NixOS tests ===

  test_nixos_has_strip_metadata = assert' (
    lib.hasInfix "strip metadata" nixosServicesText
    && lib.hasInfix "strip-metadata-nautilus" nixosServicesText
  ) "NixOS services.nix must define strip-metadata Nautilus script";

  # === Windows tests ===

  test_windows_has_strip_metadata_label = assert' (lib.hasInfix "strip metadata" windowsDscText) "Windows DSC must use the 'strip metadata' label";

  # === Integration tests ===

  test_plasma_desktop_has_strip_metadata_command = assert' (hasStripMetadataCommand plasmaDesktopText) "Plasma desktop entry must invoke strip-metadata";

  test_nautilus_script_has_strip_metadata_command = assert' (hasStripMetadataCommand nautilusScriptText) "Nautilus script must invoke strip-metadata";

  test_windows_dsc_has_strip_metadata_command = assert' (hasStripMetadataCommand windowsDscText) "Windows DSC must invoke strip-metadata in all command entries";

  # === Behavioral tests ===

  test_exiftool_preserves_icc_profiles = assert' (lib.hasInfix "--icc_profile:all" utilsShText) "utils.sh exiftool command must include --icc_profile:all to preserve ICC color profiles";

  allTests = [
    test_single_strip_metadata_workflow_exists
    test_strip_metadata_uses_public_item
    test_macos_workflow_ordering
    test_macos_workflow_has_strip_metadata_command
    test_nixos_has_strip_metadata
    test_windows_has_strip_metadata_label
    test_plasma_desktop_has_strip_metadata_command
    test_nautilus_script_has_strip_metadata_command
    test_windows_dsc_has_strip_metadata_command
    test_exiftool_preserves_icc_profiles
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "strip-metadata cross-platform parity tests passed";
}
