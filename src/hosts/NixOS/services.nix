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
  openManualScript = pkgs.writeShellScript "nucleus-open-manual" ''
    set -eu
    manual="''${NUCLEUS_REPO_ROOT:?NUCLEUS_REPO_ROOT not set}/${config.nucleus.hostManualFile}"
    exec ${pkgs.xdg-utils}/bin/xdg-open "$manual"
  '';

  # Wrapper for Nautilus script that delegates to nucleus-gs-pdf-opt (from home.packages).
  gsPdfOptScript = pkgs.writeShellScript "nucleus-gs-pdf-opt-nautilus" ''
    exec nucleus-gs-pdf-opt "$@"
  '';
in
lib.mkIf pkgs.stdenv.isLinux {
  assertions = [
    {
      assertion = config.nucleus.hostManualFile != null;
      message = "NixOS/services.nix: nucleus.hostManualFile must be set (e.g. in src/hosts/NixOS/default.nix).";
    }
  ];

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

    # Nautilus: right-click → Scripts → gs optimize pdf
    ".local/share/nautilus/scripts/gs optimize pdf" = {
      source = gsPdfOptScript;
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

    # Dolphin: right-click → gs optimize pdf (5 presets as sub-actions)
    ".local/share/kio/servicemenus/nucleus-gs-pdf-opt.desktop" = {
      text = ''
        [Desktop Entry]
        Type=Service
        ServiceTypes=KonqPopupMenu/Plugin
        MimeType=application/pdf;
        Actions=gsPdfOptDefault;gsPdfOptEbook;gsPdfOptScreen;gsPdfOptPrinter;gsPdfOptPrepress

        [Desktop Action gsPdfOptDefault]
        Name=gs optimize pdf (default)
        Exec=nucleus-gs-pdf-opt --preset default %f
        Icon=application-pdf

        [Desktop Action gsPdfOptEbook]
        Name=gs optimize pdf (ebook)
        Exec=nucleus-gs-pdf-opt --preset ebook %f
        Icon=application-pdf

        [Desktop Action gsPdfOptScreen]
        Name=gs optimize pdf (screen)
        Exec=nucleus-gs-pdf-opt --preset screen %f
        Icon=application-pdf

        [Desktop Action gsPdfOptPrinter]
        Name=gs optimize pdf (printer)
        Exec=nucleus-gs-pdf-opt --preset printer %f
        Icon=application-pdf

        [Desktop Action gsPdfOptPrepress]
        Name=gs optimize pdf (prepress)
        Exec=nucleus-gs-pdf-opt --preset prepress %f
        Icon=application-pdf
      '';
    };
  };
}
