# tests/src/gs-pdf-opt-presets-tests.nix — Verify cross-platform preset parity.
#
# Validates that all 5 Ghostscript PDF optimization presets are defined
# consistently across macOS, NixOS, and Windows context menu configurations.

let
  lib = import <nixpkgs/lib>;
  macServicesText = builtins.readFile ../../src/hosts/MacBook/services.nix;
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
    allPresetsPresent macServicesText
    && lib.hasInfix "optimize pdf - default" macServicesText
    && lib.hasInfix "optimize pdf - ebook" macServicesText
    && lib.hasInfix "optimize pdf - prepress" macServicesText
    && lib.hasInfix "optimize pdf - printer" macServicesText
    && lib.hasInfix "optimize pdf - screen" macServicesText
  ) "macOS services.nix must define all 5 presets with 'optimize pdf - X' labels";

  test_no_old_gs_labels_in_macos = assert' (noOldLabel macServicesText) "macOS services.nix must not contain the old 'gs optimize pdf' label";

  test_macos_presets_sorted = assert' (
    let
      # Check occurrences of preset labels appear in alphabetical order.
      posDefault = builtins.stringLength (
        builtins.head (builtins.split "optimize pdf \\(default\\)" macServicesText)
      );
      posEbook = builtins.stringLength (
        builtins.head (builtins.split "optimize pdf \\(ebook\\)" macServicesText)
      );
      posPrepress = builtins.stringLength (
        builtins.head (builtins.split "optimize pdf \\(prepress\\)" macServicesText)
      );
      posPrinter = builtins.stringLength (
        builtins.head (builtins.split "optimize pdf \\(printer\\)" macServicesText)
      );
      posScreen = builtins.stringLength (
        builtins.head (builtins.split "optimize pdf \\(screen\\)" macServicesText)
      );
    in
    posDefault < posEbook
    && posEbook < posPrepress
    && posPrepress < posPrinter
    && posPrinter < posScreen
  ) "macOS services.nix presets must be in alphabetical order (d < e < p < p < s)";

  test_all_5_presets_in_nixos = assert' (
    allPresetsPresent nixosServicesText
    && lib.hasInfix "optimize pdf - default" nixosServicesText
    && lib.hasInfix "optimize pdf - ebook" nixosServicesText
    && lib.hasInfix "optimize pdf - prepress" nixosServicesText
    && lib.hasInfix "optimize pdf - printer" nixosServicesText
    && lib.hasInfix "optimize pdf - screen" nixosServicesText
  ) "NixOS services.nix must define all 5 presets with 'optimize pdf - X' labels";

  test_no_old_gs_labels_in_nixos = assert' (noOldLabel nixosServicesText) "NixOS services.nix must not contain the old 'gs optimize pdf' label";

  test_nixos_presets_sorted = assert' (
    let
      posDefault = builtins.stringLength (
        builtins.head (builtins.split "optimize pdf - default" nixosServicesText)
      );
      posEbook = builtins.stringLength (
        builtins.head (builtins.split "optimize pdf - ebook" nixosServicesText)
      );
      posPrepress = builtins.stringLength (
        builtins.head (builtins.split "optimize pdf - prepress" nixosServicesText)
      );
      posPrinter = builtins.stringLength (
        builtins.head (builtins.split "optimize pdf - printer" nixosServicesText)
      );
      posScreen = builtins.stringLength (
        builtins.head (builtins.split "optimize pdf - screen" nixosServicesText)
      );
    in
    posDefault < posEbook
    && posEbook < posPrepress
    && posPrepress < posPrinter
    && posPrinter < posScreen
  ) "NixOS services.nix presets must be in alphabetical order (d < e < p < p < s)";

  test_nixos_nautilus_has_mime_guard = assert' (
    lib.hasInfix "file --mime-type" nixosServicesText
    && lib.hasInfix "application/pdf" nixosServicesText
  ) "NixOS Nautilus scripts must have MIME-type guards";

  test_all_5_presets_in_windows = assert' (
    allPresetsPresent windowsDscText
    && lib.hasInfix "optimize pdf (default)" windowsDscText
    && lib.hasInfix "optimize pdf (ebook)" windowsDscText
    && lib.hasInfix "optimize pdf (prepress)" windowsDscText
    && lib.hasInfix "optimize pdf (printer)" windowsDscText
    && lib.hasInfix "optimize pdf (screen)" windowsDscText
  ) "Windows DSC must define all 5 presets with 'optimize pdf (X)' labels";

  test_no_old_gs_labels_in_windows = assert' (noOldLabel windowsDscText) "Windows DSC must not contain the old 'gs optimize pdf' label";

  test_windows_presets_sorted = assert' (
    let
      posDefault = builtins.stringLength (
        builtins.head (builtins.split "optimize pdf \\(default\\)" windowsDscText)
      );
      posEbook = builtins.stringLength (
        builtins.head (builtins.split "optimize pdf \\(ebook\\)" windowsDscText)
      );
      posPrepress = builtins.stringLength (
        builtins.head (builtins.split "optimize pdf \\(prepress\\)" windowsDscText)
      );
      posPrinter = builtins.stringLength (
        builtins.head (builtins.split "optimize pdf \\(printer\\)" windowsDscText)
      );
      posScreen = builtins.stringLength (
        builtins.head (builtins.split "optimize pdf \\(screen\\)" windowsDscText)
      );
    in
    posDefault < posEbook
    && posEbook < posPrepress
    && posPrepress < posPrinter
    && posPrinter < posScreen
  ) "Windows DSC presets must be in alphabetical order (d < e < p < p < s)";

  test_windows_scoped_to_pdf = assert' (lib.hasInfix "SystemFileAssociations\\\\.pdf" windowsDscText) "Windows DSC must scope to PDF files via SystemFileAssociations\\.pdf";

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
  ];
in
{
  success = true;
  testCount = builtins.length allTests;
  message = "gs-pdf-opt cross-platform preset parity tests passed";
}
