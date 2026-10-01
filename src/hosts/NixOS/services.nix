# NixOS/services.nix - context-menu entries for Nautilus and Dolphin. Both
# delegate to one script that resolves the host manual through NUCLEUS_REPO_ROOT.
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
  overlay = (import ../../modules/lib/users-overlay.nix { inherit lib; }).mkUserOverlay {
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

  # PDF optimization presets, numbered so they sort on every platform and kept
  # by hand in quality-descending order to match macOS and Windows.
  # check-suppress:config-method: method 1 (writable symlink) -- repo edits take effect without rebuild.
  # Nautilus Scripts cannot declare a MIME filter, so the entry applies to
  # every selection and strip-metadata reports what it could not process in a
  # modal dialog. Declared formats: src/modules/lib/strip-metadata-types.nix.
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

  # Nautilus Scripts cannot declare a MIME filter, so this entry is offered for
  # every selection; strip-metadata reports whatever it could not process in a
  # modal dialog (--dialog). Declared input formats:
  # src/modules/lib/strip-metadata-types.nix.
  stripMetadataNautilusScript = pkgs.writeNucleusShellApplication {
    name = "strip-metadata-nautilus";
    text = ''
      exec '${../../scripts/integrations/configure-file-manager-strip-metadata.sh}' "$@"
    '';
  };
in
lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
  home.file = {
    ".local/share/nautilus/scripts/open nucleus manual" = {
      source = "${openManualScript}/bin/nucleus-open-manual";
      executable = true;
    };

    ".local/share/nautilus/scripts/optimize PDF - (1) default" = {
      source = optimizePdfNautilusScripts.default;
      executable = true;
    };
    ".local/share/nautilus/scripts/optimize PDF - (2) prepress" = {
      source = optimizePdfNautilusScripts.prepress;
      executable = true;
    };
    ".local/share/nautilus/scripts/optimize PDF - (3) printer" = {
      source = optimizePdfNautilusScripts.printer;
      executable = true;
    };
    ".local/share/nautilus/scripts/optimize PDF - (4) ebook" = {
      source = optimizePdfNautilusScripts.ebook;
      executable = true;
    };
    ".local/share/nautilus/scripts/optimize PDF - (5) screen" = {
      source = optimizePdfNautilusScripts.screen;
      executable = true;
    };

    ".local/share/nautilus/scripts/strip metadata" = {
      source = "${stripMetadataNautilusScript}/bin/nucleus-strip-metadata-nautilus";
      executable = true;
    };

  };

  # Writable symlinks to the live repo, created against the LIVE repo root so repo
  # edits take effect without a rebuild. These run before
  # protect-out-of-store-symlinks so the links get hardened.
  home.activation = {
    # Shared script that Nautilus and Dolphin both invoke.
    seed-open-manual = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
        "${config.home.homeDirectory}/.local/lib/nucleus/open-manual" \
        "src/scripts/integrations/open-host-manual.sh" \
    '';

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

    # Dolphin: right-click → strip metadata (all metadata-supportable formats).
    # check-suppress:config-method: method 1 (writable symlink) -- the desktop file can be updated in-place; no rebuild needed.
    seed-nucleus-strip-metadata-desktop = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
        "${config.home.homeDirectory}/.local/share/kio/servicemenus/nucleus-strip-metadata.desktop" \
        "${overlay.toRepoRelPath (overlay.selectFile "plasma" "desktop/nucleus-strip-metadata.desktop")}" \
    '';
  };
}
