# NixOS/services.nix — Right-click context menu entries for Linux file managers.
#
# Adds "Open Nucleus Manual" to Nautilus (GNOME) and Dolphin (KDE) context
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

    # Nautilus: right-click → Scripts → Open Nucleus Manual
    ".local/share/nautilus/scripts/Open Nucleus Manual" = {
      source = openManualScript;
      executable = true;
    };

    # Dolphin: right-click → Open Nucleus Manual
    ".local/share/kio/servicemenus/nucleus-manual.desktop" = {
      text = ''
        [Desktop Entry]
        Type=Service
        ServiceTypes=KonqPopupMenu/Plugin
        MimeType=all/all;
        Actions=openNucleusManual

        [Desktop Action openNucleusManual]
        Name=Open Nucleus Manual
        Exec=${openManualScript}
        Icon=help-contents
      '';
    };
  };
}
