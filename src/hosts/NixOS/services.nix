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
  };
}
