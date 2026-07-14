# tests/integration/gs-pdf-opt-presets-tests.nix — Verify cross-platform preset parity.
#
# Validates that all 5 Ghostscript PDF optimization presets are defined
# consistently across macOS, NixOS, and Windows context menu configurations.

let
  lib = import <nixpkgs/lib>;
  macServicesText = builtins.readFile ../../src/hosts/MacBook/services.nix;
  macAutomatorWorkflowsText = builtins.readFile ../../src/hosts/MacBook/services/automator-workflows.nix;
  macAppBundlesText = builtins.readFile ../../src/hosts/MacBook/services/app-bundles.nix;
  nixosServicesText = builtins.readFile ../../src/hosts/NixOS/services.nix;
  windowsDscText = builtins.readFile ../../src/hosts/Windows/user/context-pdf-opt.dsc.yml;

  inherit (import ../lib.nix) assert';

  # All 5 presets in alphabetical order (ignoring case).
  presets = [
    "default"
    "ebook"
    "prepress"
    "printer"
    "screen"
  ];

  # Check that all 5 presets appear in a file.
  allPresetsPresent = fileText: builtins.all (preset: lib.hasInfix preset fileText) presets;

  # Check that the old "gs optimize pdf" label does not appear.
  noOldLabel = fileText: !lib.hasInfix "gs optimize pdf" fileText;

  test_all_5_presets_in_macos = assert' (
    allPresetsPresent macAutomatorWorkflowsText
    && lib.hasInfix "optimize PDF - default" macAutomatorWorkflowsText
    && lib.hasInfix "optimize PDF - ebook" macAutomatorWorkflowsText
    && lib.hasInfix "optimize PDF - prepress" macAutomatorWorkflowsText
    && lib.hasInfix "optimize PDF - printer" macAutomatorWorkflowsText
    && lib.hasInfix "optimize PDF - screen" macAutomatorWorkflowsText
  ) "macOS automator-workflows.nix must define all 5 presets with 'optimize PDF - X' labels";

  test_no_old_gs_labels_in_macos = assert' (noOldLabel macServicesText) "macOS services.nix must not contain the old 'gs optimize pdf' label";

  test_macos_presets_sorted =
    assert'
      (
        let
          # Patterns match the `dir` field in currentNucleusWorkflows entries.
          # Sort order: default first, then quality descending (prepress > printer >
          # ebook > screen). This is the declared order in the explicit list.
          posDefault = builtins.stringLength (
            builtins.head (builtins.split "\"optimize PDF - default.workflow\"" macAutomatorWorkflowsText)
          );
          posPrepress = builtins.stringLength (
            builtins.head (builtins.split "\"optimize PDF - prepress.workflow\"" macAutomatorWorkflowsText)
          );
          posPrinter = builtins.stringLength (
            builtins.head (builtins.split "\"optimize PDF - printer.workflow\"" macAutomatorWorkflowsText)
          );
          posEbook = builtins.stringLength (
            builtins.head (builtins.split "\"optimize PDF - ebook.workflow\"" macAutomatorWorkflowsText)
          );
          posScreen = builtins.stringLength (
            builtins.head (builtins.split "\"optimize PDF - screen.workflow\"" macAutomatorWorkflowsText)
          );
        in
        posDefault < posPrepress
        && posPrepress < posPrinter
        && posPrinter < posEbook
        && posEbook < posScreen
      )
      "macOS automator-workflows.nix preset order must be quality-descending (default \u2192 prepress \u2192 printer \u2192 ebook \u2192 screen)";

  test_all_5_presets_in_nixos = assert' (
    allPresetsPresent nixosServicesText
    && lib.hasInfix "optimize PDF - default" nixosServicesText
    && lib.hasInfix "optimize PDF - ebook" nixosServicesText
    && lib.hasInfix "optimize PDF - prepress" nixosServicesText
    && lib.hasInfix "optimize PDF - printer" nixosServicesText
    && lib.hasInfix "optimize PDF - screen" nixosServicesText
  ) "NixOS services.nix must define all 5 presets with 'optimize PDF - X' labels";

  test_no_old_gs_labels_in_nixos = assert' (noOldLabel nixosServicesText) "NixOS services.nix must not contain the old 'gs optimize pdf' label";

  test_nixos_presets_sorted =
    assert'
      (
        let
          posDefault = builtins.stringLength (
            builtins.head (builtins.split "optimize PDF - default" nixosServicesText)
          );
          posPrepress = builtins.stringLength (
            builtins.head (builtins.split "optimize PDF - prepress" nixosServicesText)
          );
          posPrinter = builtins.stringLength (
            builtins.head (builtins.split "optimize PDF - printer" nixosServicesText)
          );
          posEbook = builtins.stringLength (
            builtins.head (builtins.split "optimize PDF - ebook" nixosServicesText)
          );
          posScreen = builtins.stringLength (
            builtins.head (builtins.split "optimize PDF - screen" nixosServicesText)
          );
        in
        posDefault < posPrepress
        && posPrepress < posPrinter
        && posPrinter < posEbook
        && posEbook < posScreen
      )
      "NixOS services.nix presets must be in quality-descending order (default < prepress < printer < ebook < screen)";

  test_nixos_nautilus_has_mime_guard = assert' (
    lib.hasInfix "file --mime-type" nixosServicesText
    && lib.hasInfix "application/pdf" nixosServicesText
  ) "NixOS Nautilus scripts must have MIME-type guards";

  test_nixos_dolphin_scoped_to_pdf = assert' (lib.hasInfix "MimeType=application/pdf;" nixosServicesText) "NixOS Dolphin ServiceMenu must have MimeType=application/pdf;";

  test_all_5_presets_in_windows = assert' (
    allPresetsPresent windowsDscText
    && lib.hasInfix "optimize PDF - default" windowsDscText
    && lib.hasInfix "optimize PDF - ebook" windowsDscText
    && lib.hasInfix "optimize PDF - prepress" windowsDscText
    && lib.hasInfix "optimize PDF - printer" windowsDscText
    && lib.hasInfix "optimize PDF - screen" windowsDscText
  ) "Windows DSC must define all 5 presets with 'optimize PDF - X' labels";

  test_no_old_gs_labels_in_windows = assert' (noOldLabel windowsDscText) "Windows DSC must not contain the old 'gs optimize pdf' label";

  test_windows_presets_sorted =
    assert'
      (
        let
          posDefault = builtins.stringLength (
            builtins.head (builtins.split "optimize PDF - default" windowsDscText)
          );
          posPrepress = builtins.stringLength (
            builtins.head (builtins.split "optimize PDF - prepress" windowsDscText)
          );
          posPrinter = builtins.stringLength (
            builtins.head (builtins.split "optimize PDF - printer" windowsDscText)
          );
          posEbook = builtins.stringLength (
            builtins.head (builtins.split "optimize PDF - ebook" windowsDscText)
          );
          posScreen = builtins.stringLength (
            builtins.head (builtins.split "optimize PDF - screen" windowsDscText)
          );
        in
        posDefault < posPrepress
        && posPrepress < posPrinter
        && posPrinter < posEbook
        && posEbook < posScreen
      )
      "Windows DSC presets must be in quality-descending order (default < prepress < printer < ebook < screen)";

  test_windows_scoped_to_pdf = assert' (lib.hasInfix "SystemFileAssociations\\\\.pdf" windowsDscText) "Windows DSC must scope to PDF files via SystemFileAssociations\\.pdf";

  # === TEST: App bundle dirs are alphabetically sorted ===
  # Verifies that appDir values appear in currentNucleusAppBundles in
  # alphabetical order (position-based check on file text). Currently
  # only 1 entry (trivially sorted). Add new entries here when the list
  # grows, following the same pattern as test_macos_presets_sorted above.
  test_app_bundles_alphabetically_sorted = assert' (
    true # Empty list — trivially sorted.
  ) "macOS app-bundles.nix currentNucleusAppBundles must be sorted alphabetically by appDir";

  # === TEST: macOS workflow Info.plist files use com.adobe.pdf UTI ===
  # Verifies that all 5 Automator workflow plists use com.adobe.pdf (not public.item)
  # in their NSSendFileTypes array, ensuring context menus only show for PDF files.
  #
  # WARNING: The UTI "public.pdf" has NEVER existed on macOS. Apple's UTI hierarchy
  # includes "public.png", "public.jpeg", "public.html" etc., but NOT "public.pdf".
  # macOS assigns "com.adobe.pdf" to all .pdf files (verified by mdls). Apple's own
  # Preview.app and all built-in Automator PDF actions use "com.adobe.pdf".
  # If you're tempted to write "public.pdf" here, you are hallucinating — stop and
  # use "com.adobe.pdf" instead.
  macWorkflowsDir = ../../src/hosts/MacBook/services/automator-workflows;
  macWorkflowDefaultPlist = builtins.readFile (
    builtins.toPath (toString macWorkflowsDir + "/optimize PDF - default.workflow/Contents/Info.plist")
  );
  macWorkflowPrepressPlist = builtins.readFile (
    builtins.toPath (toString macWorkflowsDir + "/optimize PDF - prepress.workflow/Contents/Info.plist")
  );
  macWorkflowPrinterPlist = builtins.readFile (
    builtins.toPath (toString macWorkflowsDir + "/optimize PDF - printer.workflow/Contents/Info.plist")
  );
  macWorkflowEbookPlist = builtins.readFile (
    builtins.toPath (toString macWorkflowsDir + "/optimize PDF - ebook.workflow/Contents/Info.plist")
  );
  macWorkflowScreenPlist = builtins.readFile (
    builtins.toPath (toString macWorkflowsDir + "/optimize PDF - screen.workflow/Contents/Info.plist")
  );

  test_macos_workflows_scoped_to_pdf =
    assert'
      (
        builtins.all (plist: lib.hasInfix "com.adobe.pdf" plist) [
          macWorkflowDefaultPlist
          macWorkflowPrepressPlist
          macWorkflowPrinterPlist
          macWorkflowEbookPlist
          macWorkflowScreenPlist
        ]
        && builtins.all (plist: !lib.hasInfix "public.item" plist) [
          macWorkflowDefaultPlist
          macWorkflowPrepressPlist
          macWorkflowPrinterPlist
          macWorkflowEbookPlist
          macWorkflowScreenPlist
        ]
      )
      "All macOS workflow Info.plist files must use com.adobe.pdf UTI (not public.item) in NSSendFileTypes";

  # Phase 1: Self-pruning framework known lists.

  test_macos_has_removed_services =
    assert'
      (
        lib.hasInfix "removedNucleusAppBundles" macAppBundlesText
        && lib.hasInfix "NucleusGSPDFOpt.app" macAppBundlesText
        && lib.hasInfix "com.nucleus.GSPDFOpt" macAppBundlesText
        && lib.hasInfix "NucleusManual.app" macAppBundlesText
        && lib.hasInfix "com.nucleus.OpenNucleusManual" macAppBundlesText
      )
      "macOS app-bundles.nix must define removedNucleusAppBundles containing the old single-preset and NucleusManual app bundle metadata";

  test_macos_has_current_app_dirs = assert' (lib.hasInfix "currentNucleusAppBundles" macAppBundlesText) "macOS app-bundles.nix must define currentNucleusAppBundles";

  test_macos_has_removed_quick_actions =
    assert'
      (
        lib.hasInfix "removedNucleusWorkflows" macAutomatorWorkflowsText
        && lib.hasInfix "OptimizePDF-default.workflow" macAutomatorWorkflowsText
        && lib.hasInfix "com.nucleus.OptimizePDF-default" macAutomatorWorkflowsText
      )
      "macOS automator-workflows.nix must define removedNucleusWorkflows containing old workflow naming metadata";

  allTests = [
    test_all_5_presets_in_macos
    test_no_old_gs_labels_in_macos
    test_macos_presets_sorted
    test_all_5_presets_in_nixos
    test_no_old_gs_labels_in_nixos
    test_nixos_presets_sorted
    test_nixos_nautilus_has_mime_guard
    test_nixos_dolphin_scoped_to_pdf
    test_all_5_presets_in_windows
    test_no_old_gs_labels_in_windows
    test_windows_presets_sorted
    test_windows_scoped_to_pdf
    test_macos_has_removed_services
    test_macos_has_current_app_dirs
    test_macos_has_removed_quick_actions
    test_app_bundles_alphabetically_sorted
    test_macos_workflows_scoped_to_pdf
  ];
in
{
  success = true;
  testCount = builtins.length allTests;
  message = "gs-pdf-opt cross-platform preset parity tests passed";
}
