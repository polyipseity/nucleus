# NixOS/services.nix — Right-click context menu entries for Linux file managers.
#
# Adds "open nucleus manual" to Nautilus (GNOME) and Dolphin (KDE) context
# menus. Both delegate to a shared script that resolves the host manual path
# via NUCLEUS_REPO_ROOT at runtime and opens it with xdg-open.
{
  config,
  lib,
  pkgs,
  repoRoot,
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
  overlay = (import ../../modules/lib/users-overlay.nix).mkUserOverlay {
    inherit effectiveUsername repoRoot;
  };

  openManualScript = pkgs.writeNucleusShellApplication {
    name = "open-manual";
    runtimeInputs = [ pkgs.xdg-utils ];
    text = ''
      exec '${../../scripts/integrations/open-host-manual.sh}' '${repoRoot}/src/hosts/NixOS/MANUAL.md' "$@"
    '';
  };

  # Ghostscript PDF optimization presets (quality descending).
  # Sorting policy: manually maintained in quality-descending order.
  # Must match macOS and Windows ordering (default → prepress → printer → ebook → screen).
  optimizePdfPresets = [
    "default"
    "prepress"
    "printer"
    "ebook"
    "screen"
  ];

  mkOptimizePdfNautilus =
    preset:
    pkgs.writeNucleusShellApplication {
      name = "optimize-pdf-nautilus-${preset}";
      runtimeInputs = [ pkgs.file ];
      text = ''
        exec '${../../scripts/integrations/configure-file-manager-optimize-pdf.sh}' '${preset}' "$@"
      '';
    };

  optimizePdfNautilusScripts = builtins.listToAttrs (
    map (p: {
      name = p;
      value = "${mkOptimizePdfNautilus p}/bin/nucleus-optimize-pdf-nautilus-${p}";
    }) optimizePdfPresets
  );
in
lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
  home.file = {
    # Shared script that Nautilus and Dolphin both invoke
    # check-suppress:config-method: method 1 (writable symlink) -- repo edits take effect without rebuild.
    ".local/lib/nucleus/open-manual" = {
      source = config.lib.file.mkOutOfStoreSymlink "${repoRoot}/src/scripts/integrations/open-host-manual.sh";
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
      source = optimizePdfNautilusScripts.default;
      executable = true;
    };
    ".local/share/nautilus/scripts/optimize PDF - prepress" = {
      source = optimizePdfNautilusScripts.prepress;
      executable = true;
    };
    ".local/share/nautilus/scripts/optimize PDF - printer" = {
      source = optimizePdfNautilusScripts.printer;
      executable = true;
    };
    ".local/share/nautilus/scripts/optimize PDF - ebook" = {
      source = optimizePdfNautilusScripts.ebook;
      executable = true;
    };
    ".local/share/nautilus/scripts/optimize PDF - screen" = {
      source = optimizePdfNautilusScripts.screen;
      executable = true;
    };

    # Dolphin: right-click → open nucleus manual
    ".local/share/kio/servicemenus/nucleus-manual.desktop" = {
      # check-suppress:config-method: method 1 (writable symlink) -- repo edits take effect without rebuild.
      source = config.lib.file.mkOutOfStoreSymlink (
        overlay.selectFile "plasma" "desktop/nucleus-manual.desktop"
      );
    };

    # Dolphin: right-click → optimize PDF (5 presets as sub-actions)
    ".local/share/kio/servicemenus/nucleus-optimize-pdf.desktop" = {
      # check-suppress:config-method: method 1 (writable symlink) -- the GS PDF Opt preset file can be updated in-place; no rebuild needed after adding/changing presets.
      source = config.lib.file.mkOutOfStoreSymlink (
        overlay.selectFile "plasma" "desktop/nucleus-optimize-pdf.desktop"
      );
    };
  };
}
