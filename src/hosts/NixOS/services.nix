# NixOS/services.nix — Right-click context menu entries for Linux file managers.
#
# Adds "open nucleus manual" to Nautilus (GNOME) and Dolphin (KDE) context
# menus. Both delegate to a shared script that resolves the host manual path
# via NUCLEUS_REPO_ROOT at runtime and opens it with xdg-open.
{ lib, pkgs, ... }:
let
  openManualScript = pkgs.writeShellScript "nucleus-open-manual" ''
    set -eu
    _nuc_repo=''${NUCLEUS_REPO_ROOT:?NUCLEUS_REPO_ROOT not set}
    exec ${pkgs.xdg-utils}/bin/xdg-open "$_nuc_repo/src/hosts/NixOS/MANUAL.md"
  '';

  # Ghostscript PDF optimization presets (quality descending).
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
    pkgs.writeShellScript "nucleus-gs-pdf-opt-nautilus-${preset}" ''
      pdfs=()
      for f in "$@"; do
        case "$(${pkgs.file}/bin/file --mime-type -b "$f" 2>/dev/null || true)" in
          application/pdf) pdfs+=("$f") ;;
        esac
      done
      if [ ''${#pdfs[@]} -gt 0 ]; then
        exec nucleus-gs-pdf-opt --preset ${preset} "''${pdfs[@]}"
      fi
    '';

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
    ".local/lib/nucleus/open-manual" = {
      source = openManualScript;
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
      text = ''
        [Desktop Entry]
        Type=Service
        ServiceTypes=KonqPopupMenu/Plugin
        MimeType=all/all;
        Actions=openNucleusManual

        [Desktop Action openNucleusManual]
        Name=open nucleus manual
        Exec=${openManualScript}
        Icon=help-contents
      '';
    };

    # Dolphin: right-click → optimize PDF (5 presets as sub-actions)
    ".local/share/kio/servicemenus/nucleus-gs-pdf-opt.desktop" = {
      text = ''
        [Desktop Entry]
        Type=Service
        ServiceTypes=KonqPopupMenu/Plugin
        MimeType=application/pdf;
        Actions=optimizePdfDefault;optimizePdfPrepress;optimizePdfPrinter;optimizePdfEbook;optimizePdfScreen

        [Desktop Action optimizePdfDefault]
        Name=optimize PDF - default
        Exec=nucleus-gs-pdf-opt --preset default %f
        Icon=application-pdf

        [Desktop Action optimizePdfPrepress]
        Name=optimize PDF - prepress
        Exec=nucleus-gs-pdf-opt --preset prepress %f
        Icon=application-pdf

        [Desktop Action optimizePdfPrinter]
        Name=optimize PDF - printer
        Exec=nucleus-gs-pdf-opt --preset printer %f
        Icon=application-pdf

        [Desktop Action optimizePdfEbook]
        Name=optimize PDF - ebook
        Exec=nucleus-gs-pdf-opt --preset ebook %f
        Icon=application-pdf

        [Desktop Action optimizePdfScreen]
        Name=optimize PDF - screen
        Exec=nucleus-gs-pdf-opt --preset screen %f
        Icon=application-pdf
      '';
    };
  };
}
