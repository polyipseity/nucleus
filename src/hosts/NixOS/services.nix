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

  # Activation helper bundle (seed-writable-symlink.sh) resolved at eval time;
  # the helper itself resolves the LIVE repo root at activation time.
  activationBundle = pkgs.callPackage ../../modules/lib/script-tree.nix { };

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

  # Office document MIME types for metadata stripping.
  # Used for Nautilus MIME guard only; the shell script handles all six types.

  stripMetadataNautilusScript = pkgs.writeNucleusShellApplication {
    name = "strip-metadata-nautilus";
    runtimeInputs = [ pkgs.file ];
    text = ''
      exec '${../../scripts/integrations/configure-file-manager-strip-metadata.sh}' "$@"
    '';
  };
in
lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
  home.file = {
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

    # Nautilus: right-click → Scripts → strip metadata
    # MIME guard handled inside the script (6 Office MIME types).
    ".local/share/nautilus/scripts/strip metadata" = {
      source = "${stripMetadataNautilusScript}/bin/nucleus-strip-metadata-nautilus";
      executable = true;
    };

  };

  # Method-1 (writable) symlinks to the live repo, created at activation time against the
  # LIVE repo root so repo edits take effect without rebuild. The writable/immutable
  # decision is owned by managedSymlinkPaths; these entries run before
  # protect-out-of-store-symlinks so the link is hardened if immutable.
  # check-suppress:config-method: method 1 (writable symlink) -- repo edits take effect without rebuild.
  home.activation = {
    # Shared script that Nautilus and Dolphin both invoke.
    seed-open-manual = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
        "${config.home.homeDirectory}/.local/lib/nucleus/open-manual" \
        "src/scripts/integrations/open-host-manual.sh" \
    '';

    # Dolphin: right-click → open nucleus manual.
    # check-suppress:config-method: method 1 (writable symlink) -- repo edits take effect without rebuild.
    seed-nucleus-manual-desktop = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
        "${config.home.homeDirectory}/.local/share/kio/servicemenus/nucleus-manual.desktop" \
        "${overlay.toRepoRelPath (overlay.selectFile "plasma" "desktop/nucleus-manual.desktop")}" \
    '';

    # Dolphin: right-click → optimize PDF (5 presets as sub-actions).
    # check-suppress:config-method: method 1 (writable symlink) -- the GS PDF Opt preset file can be updated in-place; no rebuild needed after adding/changing presets.
    seed-nucleus-optimize-pdf-desktop = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
        "${config.home.homeDirectory}/.local/share/kio/servicemenus/nucleus-optimize-pdf.desktop" \
        "${overlay.toRepoRelPath (overlay.selectFile "plasma" "desktop/nucleus-optimize-pdf.desktop")}" \
    '';

    # Dolphin: right-click → strip metadata (all Office formats).
    # check-suppress:config-method: method 1 (writable symlink) -- the desktop file can be updated in-place; no rebuild needed.
    seed-nucleus-strip-metadata-desktop = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
        "${config.home.homeDirectory}/.local/share/kio/servicemenus/nucleus-strip-metadata.desktop" \
        "${overlay.toRepoRelPath (overlay.selectFile "plasma" "desktop/nucleus-strip-metadata.desktop")}" \
    '';
  };
}
