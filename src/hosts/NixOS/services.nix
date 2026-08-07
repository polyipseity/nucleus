# NixOS/services.nix — Right-click context menu entries for Linux file managers.
#
# Adds "open nucleus manual" to Nautilus (GNOME) and Dolphin (KDE) context
# menus. Both delegate to a shared script that resolves the host manual path
# via NUCLEUS_REPO_ROOT at runtime and opens it with xdg-open.
{
  config,
  lib,
  pkgs,
  managedUsername ? null,
  username ? null,
  ...
}:
let
  effectiveUsername =
    if managedUsername != null then
      managedUsername
    else if username != null then
      username
    else
      config.home.username;
  repoRoot = builtins.getEnv "NUCLEUS_REPO_ROOT";
  overlay = (import ../../modules/lib/users-overlay.nix).mkUserOverlay {
    inherit effectiveUsername repoRoot;
  };

  openManualScript = pkgs.writeNucleusShellApplication {
    name = "open-manual";
    runtimeInputs = [ pkgs.xdg-utils ];
    text = ''
      exec '${../../scripts/integrations/open-host-manual.sh}' '${builtins.getEnv "NUCLEUS_REPO_ROOT"}/src/hosts/NixOS/MANUAL.md' "$@"
    '';
  };

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

  mkGSPdfOptNautilus =
    preset:
    pkgs.writeNucleusShellApplication {
      name = "gs-pdf-opt-nautilus-${preset}";
      runtimeInputs = [ pkgs.file ];
      text = ''
        exec '${../../scripts/integrations/configure-file-manager-pdf-opt.sh}' '${preset}' "$@"
      '';
    };

  gsPdfOptNautilusScripts = builtins.listToAttrs (
    map (p: {
      name = p;
      value = "${mkGSPdfOptNautilus p}/bin/nucleus-gs-pdf-opt-nautilus-${p}";
    }) gsPdfOptPresets
  );
in
lib.mkIf pkgs.stdenv.isLinux {
  home.file = {
    # Shared script that Nautilus and Dolphin both invoke
    # check-suppress:config-method: method 1 (writable symlink) -- repo edits take effect without rebuild.
    ".local/lib/nucleus/open-manual" = {
      source = config.lib.file.mkOutOfStoreSymlink "${builtins.getEnv "NUCLEUS_REPO_ROOT"}/src/scripts/integrations/open-host-manual.sh";
      executable = true;
    };

    # Nautilus: right-click → Scripts → open nucleus manual
    ".local/share/nautilus/scripts/open nucleus manual" = {
      source = "${openManualScript}/bin/nucleus-open-manual";
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
      # check-suppress:config-method: method 1 (writable symlink) -- repo edits take effect without rebuild.
      source = config.lib.file.mkOutOfStoreSymlink (overlay.selectFile "plasma" "desktop/nucleus-manual.desktop");
    };

    # Dolphin: right-click → optimize PDF (5 presets as sub-actions)
    ".local/share/kio/servicemenus/nucleus-gs-pdf-opt.desktop" = {
      # check-suppress:config-method: method 1 (writable symlink) -- the GS PDF Opt preset file can be updated in-place; no rebuild needed after adding/changing presets.
      source = config.lib.file.mkOutOfStoreSymlink (overlay.selectFile "plasma" "desktop/nucleus-gs-pdf-opt.desktop");
    };
  };
}
