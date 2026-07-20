# NixOS/services.nix — Right-click context menu entries for Linux file managers.
#
# Adds "open nucleus manual" to Nautilus (GNOME) and Dolphin (KDE) context
# menus. Both delegate to a shared script that resolves the host manual path
# via NUCLEUS_REPO_ROOT at runtime and opens it with xdg-open.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  openManualScript = pkgs.writeShellScript "nucleus-open-manual" (
    builtins.replaceStrings
      [ "__MANUAL_OPENER__" "__HOST_MANUAL_PATH__" ]
      [
        "${pkgs.xdg-utils}/bin/xdg-open"
        "${builtins.getEnv "NUCLEUS_REPO_ROOT"}/src/hosts/NixOS/MANUAL.md"
      ]
      (builtins.readFile ./../../scripts/integrations/open-host-manual.sh)
  );

  # Ghostscript PDF optimization presets (quality descending).
  # Sorting policy: manually maintained in quality-descending order.
  # Must match macOS and Windows ordering (default → prepress → printer → ebook → screen).
  gsPdfOptPresets = [
    "default"
    "prepress"
    "printer"
    "ebook"
    "screen"
  ];

  # Per-preset Nautilus script with MIME-type guard (Nautilus scripts have no built-in MIME filtering).
  mkGSPdfOptNautilus =
    preset:
    pkgs.writeShellScript "nucleus-gs-pdf-opt-nautilus-${preset}" (
      builtins.replaceStrings
        [ "__FILE_BIN__" "__GS_PDF_OPT_PRESET__" ]
        [ "${pkgs.file}/bin/file" preset ]
        (builtins.readFile ./../../scripts/integrations/configure-file-manager-pdf-opt.sh)
    );

  gsPdfOptNautilusScripts = builtins.listToAttrs (
    map (p: {
      name = p;
      value = mkGSPdfOptNautilus p;
    }) gsPdfOptPresets
  );
in
lib.mkIf pkgs.stdenv.isLinux {
  home.file = {
    # Shared script that Nautilus and Dolphin both invoke
    # Method 1 (writable symlink): repo edits take effect without rebuild.
    ".local/lib/nucleus/open-manual" = {
      source = config.lib.file.mkOutOfStoreSymlink "${builtins.getEnv "NUCLEUS_REPO_ROOT"}/src/scripts/integrations/open-host-manual.sh";
      executable = true;
    };

    # Nautilus: right-click → Scripts → open nucleus manual
    ".local/share/nautilus/scripts/open nucleus manual" = {
      source = openManualScript;
      executable = true;
    };

    # Nautilus: right-click → Scripts → optimize PDF - <preset> (5 presets)
    # Nautilus scripts have no MIME filtering; each script guards with file --mime-type.
    ".local/share/nautilus/scripts/optimize PDF - default" = {
      source = gsPdfOptNautilusScripts.default;
      executable = true;
    };
    ".local/share/nautilus/scripts/optimize PDF - prepress" = {
      source = gsPdfOptNautilusScripts.prepress;
      executable = true;
    };
    ".local/share/nautilus/scripts/optimize PDF - printer" = {
      source = gsPdfOptNautilusScripts.printer;
      executable = true;
    };
    ".local/share/nautilus/scripts/optimize PDF - ebook" = {
      source = gsPdfOptNautilusScripts.ebook;
      executable = true;
    };
    ".local/share/nautilus/scripts/optimize PDF - screen" = {
      source = gsPdfOptNautilusScripts.screen;
      executable = true;
    };

    # Dolphin: right-click → open nucleus manual
    ".local/share/kio/servicemenus/nucleus-manual.desktop" = {
      # Method 1 (writable symlink): repo edits take effect without rebuild.
      source = config.lib.file.mkOutOfStoreSymlink "${builtins.getEnv "NUCLEUS_REPO_ROOT"}/src/modules/configs/plasma/nucleus-manual.desktop";
    };

    # Dolphin: right-click → optimize PDF (5 presets as sub-actions)
    ".local/share/kio/servicemenus/nucleus-gs-pdf-opt.desktop" = {
      # Method 1 (writable symlink): the GS PDF Opt preset file can be updated in-place; no rebuild needed after adding/changing presets.
      source = config.lib.file.mkOutOfStoreSymlink "${builtins.getEnv "NUCLEUS_REPO_ROOT"}/src/modules/configs/plasma/nucleus-gs-pdf-opt.desktop";
    };
  };
}
