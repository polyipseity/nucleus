# tests/integration/strip-office-metadata-tests.nix — Verify cross-platform parity for Office metadata stripping across all 6 Office extensions.

let
  lib = import <nixpkgs/lib>;
  macAutomatorWorkflowsText = builtins.readFile ../../src/hosts/MacBook/services/automator-workflows.nix;
  nixosServicesText = builtins.readFile ../../src/hosts/NixOS/services.nix;
  windowsDscText = builtins.readFile ../../src/hosts/Windows/user/context-strip-office-metadata.dsc.yml;
  nautilusScriptText = builtins.readFile ../../src/scripts/integrations/configure-file-manager-strip-office-metadata.sh;
  plasmaDesktopText = builtins.readFile ../../src/users/default/plasma/desktop/nucleus-strip-office-metadata.desktop;

  inherit (import ../lib.nix) assert';

  # All 6 Office extensions in the canonical name set.
  extensions = [
    "word"
    "word-legacy"
    "excel"
    "excel-legacy"
    "powerpoint"
    "powerpoint-legacy"
  ];

  # All 6 file extensions (dot-prefixed) for Windows DSC checks.
  fileExtensions = [
    ".doc"
    ".docx"
    ".xls"
    ".xlsx"
    ".ppt"
    ".pptx"
  ];

  # All 6 MIME types for cross-platform MIME guard checks.
  mimeTypes = [
    "application/msword"
    "application/vnd.ms-excel"
    "application/vnd.ms-powerpoint"
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    "application/vnd.openxmlformats-officedocument.presentationml.presentation"
  ];

  # Check that all 6 variant names appear in a file.
  allExtensionsPresent = fileText: builtins.all (ext: lib.hasInfix ext fileText) extensions;

  # === macOS tests ===

  test_all_6_variants_in_macos = assert' (
    allExtensionsPresent macAutomatorWorkflowsText
    && lib.hasInfix "strip office metadata - word" macAutomatorWorkflowsText
    && lib.hasInfix "strip office metadata - excel" macAutomatorWorkflowsText
    && lib.hasInfix "strip office metadata - powerpoint" macAutomatorWorkflowsText
    && lib.hasInfix "strip office metadata - word-legacy" macAutomatorWorkflowsText
    && lib.hasInfix "strip office metadata - excel-legacy" macAutomatorWorkflowsText
    && lib.hasInfix "strip office metadata - powerpoint-legacy" macAutomatorWorkflowsText
  ) "macOS automator-workflows.nix must define all 6 strip-office-metadata variants";

  test_macos_workflow_ordering =
    assert'
      (
        let
          posOpenManual = builtins.stringLength (
            builtins.head (builtins.split "\"open nucleus manual.workflow\"" macAutomatorWorkflowsText)
          );
          posExcel = builtins.stringLength (
            builtins.head (
              builtins.split "\"strip office metadata - excel.workflow\"" macAutomatorWorkflowsText
            )
          );
          posWord = builtins.stringLength (
            builtins.head (builtins.split "\"strip office metadata - word.workflow\"" macAutomatorWorkflowsText)
          );
          posOptDefault = builtins.stringLength (
            builtins.head (builtins.split "\"optimize PDF - default.workflow\"" macAutomatorWorkflowsText)
          );
        in
        posOpenManual < posExcel && posExcel < posWord && posWord < posOptDefault
      )
      "macOS strip-office-metadata block must be between 'open nucleus manual' and 'optimize PDF' blocks";

  macWorkflowsDir = ../../src/hosts/MacBook/services/automator-workflows;
  macWorkflowWordPlist = builtins.readFile (
    builtins.toPath (
      toString macWorkflowsDir + "/strip office metadata - word.workflow/Contents/Info.plist"
    )
  );
  macWorkflowExcelPlist = builtins.readFile (
    builtins.toPath (
      toString macWorkflowsDir + "/strip office metadata - excel.workflow/Contents/Info.plist"
    )
  );
  macWorkflowPptPlist = builtins.readFile (
    builtins.toPath (
      toString macWorkflowsDir + "/strip office metadata - powerpoint.workflow/Contents/Info.plist"
    )
  );
  macWorkflowWordLegacyPlist = builtins.readFile (
    builtins.toPath (
      toString macWorkflowsDir + "/strip office metadata - word-legacy.workflow/Contents/Info.plist"
    )
  );
  macWorkflowExcelLegacyPlist = builtins.readFile (
    builtins.toPath (
      toString macWorkflowsDir + "/strip office metadata - excel-legacy.workflow/Contents/Info.plist"
    )
  );
  macWorkflowPptLegacyPlist = builtins.readFile (
    builtins.toPath (
      toString macWorkflowsDir + "/strip office metadata - powerpoint-legacy.workflow/Contents/Info.plist"
    )
  );

  test_macos_workflows_scoped_to_office_utis = assert' (
    # Each plist must contain its expected UTI in NSSendFileTypes.
    # OOXML formats use standard UTIs; legacy formats use Microsoft UTIs.
    lib.hasInfix "org.openxmlformats.wordprocessingml.document" macWorkflowWordPlist
    && lib.hasInfix "org.openxmlformats.spreadsheetml.sheet" macWorkflowExcelPlist
    && lib.hasInfix "org.openxmlformats.presentationml.presentation" macWorkflowPptPlist
    && lib.hasInfix "com.microsoft.word.doc" macWorkflowWordLegacyPlist
    && lib.hasInfix "com.microsoft.excel.xls" macWorkflowExcelLegacyPlist
    && lib.hasInfix "com.microsoft.powerpoint.ppt" macWorkflowPptLegacyPlist
    # None should use public.item (too broad).
    && !lib.hasInfix "public.item" macWorkflowWordPlist
    && !lib.hasInfix "public.item" macWorkflowExcelPlist
    && !lib.hasInfix "public.item" macWorkflowPptPlist
    && !lib.hasInfix "public.item" macWorkflowWordLegacyPlist
    && !lib.hasInfix "public.item" macWorkflowExcelLegacyPlist
    && !lib.hasInfix "public.item" macWorkflowPptLegacyPlist
  ) "All macOS strip-office-metadata Info.plist files must use per-format UTIs (not public.item)";

  # === NixOS tests ===

  test_nixos_has_strip_office_metadata = assert' (
    lib.hasInfix "strip office metadata" nixosServicesText
    && lib.hasInfix "strip-office-metadata-nautilus" nixosServicesText
  ) "NixOS services.nix must define strip-office-metadata Nautilus script and Dolphin entry";

  test_nixos_nautilus_has_mime_guard = assert' (
    lib.hasInfix "file --mime-type" nautilusScriptText
    && builtins.all (m: lib.hasInfix m nautilusScriptText) mimeTypes
  ) "NixOS Nautilus script must have MIME-type guards for all 6 Office MIME types";

  test_nixos_dolphin_scoped_to_office = assert' (builtins.all (
    m: lib.hasInfix m plasmaDesktopText
  ) mimeTypes) "NixOS Dolphin desktop entry must list all 6 Office MIME types in MimeType=";

  # === Windows tests ===

  test_windows_has_all_6_extensions = assert' (builtins.all (
    ext: lib.hasInfix ext windowsDscText
  ) fileExtensions) "Windows DSC must define entries for all 6 Office file extensions";

  test_windows_scoped_to_system_file_associations = assert' (builtins.all (
    ext: lib.hasInfix "SystemFileAssociations\\${ext}" windowsDscText
  ) fileExtensions) "Windows DSC must scope each entry to its extension via SystemFileAssociations";

  test_windows_has_strip_office_metadata_label = assert' (lib.hasInfix "strip office metadata" windowsDscText) "Windows DSC must use the 'strip office metadata' label";

  allTests = [
    test_all_6_variants_in_macos
    test_macos_workflow_ordering
    test_macos_workflows_scoped_to_office_utis
    test_nixos_has_strip_office_metadata
    test_nixos_nautilus_has_mime_guard
    test_nixos_dolphin_scoped_to_office
    test_windows_has_all_6_extensions
    test_windows_scoped_to_system_file_associations
    test_windows_has_strip_office_metadata_label
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "strip-office-metadata cross-platform parity tests passed";
}
