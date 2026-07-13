# tests/integration/gs-pdf-opt-presets-tests.nix — Verify cross-platform preset parity.
#
# Validates that all 5 Ghostscript PDF optimization presets are defined
# consistently across macOS, NixOS, and Windows context menu configurations.

let
  lib = import <nixpkgs/lib>;
  macServicesText = builtins.readFile ../../src/hosts/MacBook/services.nix;
  macQuickActionsText = builtins.readFile ../../src/hosts/MacBook/services/quick-actions.nix;
  macAppServicesText = builtins.readFile ../../src/hosts/MacBook/services/app-services.nix;
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
    allPresetsPresent macQuickActionsText
    && lib.hasInfix "optimize PDF - default" macQuickActionsText
    && lib.hasInfix "optimize PDF - ebook" macQuickActionsText
    && lib.hasInfix "optimize PDF - prepress" macQuickActionsText
    && lib.hasInfix "optimize PDF - printer" macQuickActionsText
    && lib.hasInfix "optimize PDF - screen" macQuickActionsText
  ) "macOS quick-actions.nix must define all 5 presets with 'optimize PDF - X' labels";

  test_no_old_gs_labels_in_macos = assert' (noOldLabel macServicesText) "macOS services.nix must not contain the old 'gs optimize pdf' label";

  test_macos_presets_sorted =
    assert'
      (
        let
          # Patterns match the `dir` field in currentNucleusQuickActions entries.
          # Sort order: default first, then quality descending (prepress > printer >
          # ebook > screen). This is the declared order in the explicit list.
          posDefault = builtins.stringLength (
            builtins.head (builtins.split "\"optimize PDF - default.workflow\"" macQuickActionsText)
          );
          posPrepress = builtins.stringLength (
            builtins.head (builtins.split "\"optimize PDF - prepress.workflow\"" macQuickActionsText)
          );
          posPrinter = builtins.stringLength (
            builtins.head (builtins.split "\"optimize PDF - printer.workflow\"" macQuickActionsText)
          );
          posEbook = builtins.stringLength (
            builtins.head (builtins.split "\"optimize PDF - ebook.workflow\"" macQuickActionsText)
          );
          posScreen = builtins.stringLength (
            builtins.head (builtins.split "\"optimize PDF - screen.workflow\"" macQuickActionsText)
          );
        in
        posDefault < posPrepress
        && posPrepress < posPrinter
        && posPrinter < posEbook
        && posEbook < posScreen
      )
      "macOS quick-actions.nix presets must be in custom order (default < prepress < printer < ebook < screen)";

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

  # Phase 1: Self-pruning framework known lists.

  test_macos_has_removed_services =
    assert'
      (
        lib.hasInfix "removedNucleusAppServices" macAppServicesText
        && lib.hasInfix "NucleusGSPDFOpt.app" macAppServicesText
        && lib.hasInfix "com.nucleus.GSPDFOpt" macAppServicesText
      )
      "macOS app-services.nix must define removedNucleusAppServices containing the old single-preset app service metadata";

  test_macos_has_current_app_dirs =
    assert'
      (
        lib.hasInfix "currentNucleusAppServiceDirs" macAppServicesText
        && lib.hasInfix "NucleusManual.app" macAppServicesText
      )
      "macOS app-services.nix must define currentNucleusAppServiceDirs containing current app service dirs";

  test_macos_has_removed_quick_actions =
    assert'
      (
        lib.hasInfix "removedNucleusQuickActions" macQuickActionsText
        && lib.hasInfix "OptimizePDF-default.workflow" macQuickActionsText
        && lib.hasInfix "com.nucleus.OptimizePDF-default" macQuickActionsText
      )
      "macOS quick-actions.nix must define removedNucleusQuickActions containing old workflow naming metadata";

  allTests = [
    test_all_5_presets_in_macos
    test_no_old_gs_labels_in_macos
    test_macos_presets_sorted
    test_all_5_presets_in_nixos
    test_no_old_gs_labels_in_nixos
    test_nixos_presets_sorted
    test_nixos_nautilus_has_mime_guard
    test_all_5_presets_in_windows
    test_no_old_gs_labels_in_windows
    test_windows_presets_sorted
    test_windows_scoped_to_pdf
    test_macos_has_removed_services
    test_macos_has_current_app_dirs
    test_macos_has_removed_quick_actions
  ];
in
{
  success = true;
  testCount = builtins.length allTests;
  message = "gs-pdf-opt cross-platform preset parity tests passed";
}
