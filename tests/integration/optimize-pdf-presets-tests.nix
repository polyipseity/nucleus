# tests/integration/optimize-pdf-presets-tests.nix — Verify cross-platform preset parity for all 5 Ghostscript PDF optimization presets.

let
  lib = import <nixpkgs/lib>;
  macAutomatorWorkflowsText = builtins.readFile ../../src/hosts/MacBook/services/automator-workflows/default.nix;
  nixosServicesText = builtins.readFile ../../src/hosts/NixOS/services.nix;
  windowsDscText = builtins.readFile ../../src/hosts/Windows/user/context-optimize-pdf.dsc.yml;
  nautilusScriptText = builtins.readFile ../../src/scripts/integrations/configure-file-manager-optimize-pdf.sh;
  plasmaDesktopText = builtins.readFile ../../src/users/default/plasma/desktop/nucleus-optimize-pdf.desktop;

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

  test_all_5_presets_in_macos = assert' (
    allPresetsPresent macAutomatorWorkflowsText
  ) "macOS automator-workflows.nix must define all 5 presets";

  test_all_5_presets_in_nixos = assert' (
    allPresetsPresent nixosServicesText
  ) "NixOS services.nix must define all 5 presets";

  test_all_5_presets_in_windows = assert' (
    allPresetsPresent windowsDscText
  ) "Windows DSC must define all 5 presets";

  test_nixos_nautilus_has_mime_guard = assert' (
    lib.hasInfix "file --mime-type" nautilusScriptText
    && lib.hasInfix "application/pdf" nautilusScriptText
  ) "NixOS Nautilus scripts must have MIME-type guards";

  test_nixos_dolphin_scoped_to_pdf = assert' (lib.hasInfix "MimeType=application/pdf;" plasmaDesktopText) "NixOS Dolphin ServiceMenu must ship MimeType=application/pdf; in the plasma desktop file";

  test_windows_scoped_to_pdf = assert' (lib.hasInfix "SystemFileAssociations\\.pdf" windowsDscText) "Windows DSC must scope to PDF files via SystemFileAssociations\\.pdf";

  allTests = [
    test_all_5_presets_in_macos
    test_all_5_presets_in_nixos
    test_all_5_presets_in_windows
    test_nixos_nautilus_has_mime_guard
    test_nixos_dolphin_scoped_to_pdf
    test_windows_scoped_to_pdf
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "optimize-pdf cross-platform preset parity tests passed";
}
