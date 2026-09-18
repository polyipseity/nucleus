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

  # Numbered names in quality-descending order.
  numberedNames = [
    "optimize PDF - (1) default"
    "optimize PDF - (2) prepress"
    "optimize PDF - (3) printer"
    "optimize PDF - (4) ebook"
    "optimize PDF - (5) screen"
  ];

  # On-disk macOS workflow bundles. Finder labels Quick Actions from the bundle
  # directory name, so the directories must carry the same "(N)" numbering as
  # the menu label.
  macWorkflowsDir = ../../src/hosts/MacBook/services/automator-workflows;
  macWorkflowDirEntries = builtins.readDir macWorkflowsDir;
  expectedWorkflowDirs = map (name: "${name}.workflow") numberedNames;

  # Check that all 5 presets appear in a file.
  allPresetsPresent = fileText: builtins.all (preset: lib.hasInfix preset fileText) presets;

  test_all_5_presets_in_macos = assert' (allPresetsPresent macAutomatorWorkflowsText) "macOS automator-workflows.nix must define all 5 presets";

  test_all_5_presets_in_nixos = assert' (allPresetsPresent nixosServicesText) "NixOS services.nix must define all 5 presets";

  test_all_5_presets_in_windows = assert' (allPresetsPresent windowsDscText) "Windows DSC must define all 5 presets";

  # Verify numbered naming convention (N. quality) for sort order.
  test_macos_has_numbered_names = assert' (builtins.all
    (name: lib.hasInfix name macAutomatorWorkflowsText)
    numberedNames
  ) "macOS automator-workflows.nix must use numbered names (optimize PDF - (N) quality)";

  test_macos_workflow_dirs_numbered = assert' (builtins.all
    (dirName: builtins.hasAttr dirName macWorkflowDirEntries)
    expectedWorkflowDirs
  ) "macOS optimize PDF workflow directories must be named 'optimize PDF - (N) <preset>.workflow'";

  test_macos_no_dot_numbered_dirs = assert' (lib.all
    (name: builtins.match "(.*) - [0-9]+\\..*" name == null)
    (builtins.attrNames macWorkflowDirEntries)
  ) "macOS workflow directories must not use the 'N.' dot numbering form";

  test_macos_dir_source_match_workflow_dirs = assert' (builtins.all
    (
      dirName:
      lib.hasInfix "dir = \"${dirName}\";" macAutomatorWorkflowsText
      && lib.hasInfix "source = \"\${workflowsDir}/${dirName}\";" macAutomatorWorkflowsText
    )
    expectedWorkflowDirs
  ) "macOS default.nix dir/source must reference the on-disk '(N)' workflow directory names";

  test_macos_workflow_dir_names_valid_store_names = assert' (builtins.all (
    dirName:
    builtins.match "[A-Za-z0-9+._?=-]+" (builtins.replaceStrings [ " " "(" ")" ] [ "-" "" "" ] dirName)
    != null
  ) expectedWorkflowDirs) "macOS workflow directory names must reduce to a valid Nix store-path name";

  test_nixos_has_numbered_names = assert' (builtins.all (
    name: lib.hasInfix name nixosServicesText
  ) numberedNames) "NixOS services.nix must use numbered names (optimize PDF - (N) quality)";

  test_windows_has_numbered_names = assert' (builtins.all (
    name: lib.hasInfix name windowsDscText
  ) numberedNames) "Windows DSC must use numbered names (optimize PDF - (N) quality)";

  test_plasma_has_numbered_names = assert' (builtins.all (
    name: lib.hasInfix name plasmaDesktopText
  ) numberedNames) "Plasma desktop file must use numbered names (optimize PDF - (N) quality)";

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
    test_macos_has_numbered_names
    test_macos_workflow_dirs_numbered
    test_macos_no_dot_numbered_dirs
    test_macos_dir_source_match_workflow_dirs
    test_macos_workflow_dir_names_valid_store_names
    test_nixos_has_numbered_names
    test_windows_has_numbered_names
    test_plasma_has_numbered_names
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
