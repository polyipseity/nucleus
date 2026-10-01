# MacBook/services/automator-workflows.nix - macOS Automator workflow bundles.
#
# These Automator .workflow bundles appear in the right-click context menu and
# in Services. They are deployed to ~/Library/Services/.
#
# WHY strip metadata is an allow-list, not "public.item": NSSendFileTypes is
# inclusion-only and Apple defines no exclusion key, so withholding the action
# means narrowing the list. Under "public.item" it was offered for PDFs, which
# strip-metadata must refuse. Types outside the list stay reachable from the
# CLI, and the workflow reports every input it did not process in one dialog.
#
# WHY "com.adobe.pdf" and never "public.pdf": the UTI "public.pdf" has never
# existed on macOS. Preview.app and every Apple built-in Automator PDF action
# use "com.adobe.pdf". "public.pdf" is a common hallucination; reject it.
#
# WHY home.activation and not home.file: home.file symlinks into the Nix store,
# and a symlinked .workflow bundle is not discoverable by the service menu.
# That is a Method 2 read-only deployment, so activation copies each bundle.
#
# SF Symbol rules:
#   - Verify every name against the macOS private framework. Community lists
#     are incomplete. <USER root>/state/sf-symbols.txt is generated from the
#     framework at activation, never downloaded, never committed.
#   - One name for NSIconName (Info.plist) and systemImageName (document.wflow).
#   - No custom TIFF icons: SF Symbols are resolution-independent and handle
#     dark and light mode natively.
#   - NSBackgroundColorName only affects the Touch Bar; set it to "background".
#   - Check the symbol's introduction year in name_availability.plist against
#     the host's minimum version.
#   - Known issue: NSIconName can keep a Quick Action out of the Services menu.
#     Current workflows ship it and are confirmed to appear.
#
# Thumbnail.png is the Get Info window icon, a 256x256 render produced at build
# time from the thumbnailSymbol field. Thumbnail.png alone is not enough: the
# deploy script also calls NSWorkspace.setIcon:forFile:options: to register the
# icon with IconServices, which caches by exact file path, so it cannot happen
# at build time.
{
  lib,
  pkgs,
  mkPresentationModes,
  repoRoot,
  ...
}:
let
  # Quoted so a path with spaces never reaches the Nix path parser.
  workflowsDir = ./.;

  thumbnailGenSrc = ../../scripts/generate-automator-thumbnails.m;

  # Compiled ObjC program that registers custom Finder icons via NSWorkspace.setIcon:.
  setWorkflowIcon = pkgs.runCommand "set-workflow-icon" { } ''
    ${pkgs.stdenv.cc}/bin/cc -fobjc-arc -fmodules -Wno-deprecated-declarations \
      -framework AppKit -framework Foundation \
      -o "$out" "${../../scripts/set-workflow-icon.m}"
  '';

  # WHY: store-path names allow only [A-Za-z0-9+._?=-], and the "(N)" preset
  # numbering carries parentheses, which Nix rejects in a derivation name.
  sanitizeStoreName = builtins.replaceStrings [ " " "(" ")" ] [ "-" "" "" ];

  # Build a workflow bundle with QuickLook/Thumbnail.png generated at build time.
  buildWorkflowWithThumbnail =
    wf:
    wf
    // {
      source = pkgs.runCommand "automator-${sanitizeStoreName wf.dir}" { } ''
        cp -r "${wf.source}" "$out"
        chmod -R u+w "$out"
        mkdir -p "$out/Contents/QuickLook"
        ${pkgs.stdenv.cc}/bin/cc -fobjc-arc -fmodules -framework AppKit -framework Foundation \
          -o render_symbol "${thumbnailGenSrc}"
        ./render_symbol "${wf.thumbnailSymbol}" "$out/Contents/QuickLook/Thumbnail.png"
      '';
    };

  # Sort alphabetically by entry name, except the Optimize PDF presets, which
  # form one block ordered quality-descending. The "(N)" prefix makes that order
  # sort correctly everywhere, and every block sits at its primary name. This is
  # the cross-platform convention, kept in NixOS and Windows too. Deployment
  # follows the declared order; nothing is sorted automatically.
  currentNucleusWorkflows = map buildWorkflowWithThumbnail [
    # Alphabetical before "optimize": open nucleus manual
    {
      dir = "open nucleus manual.workflow";
      enablementKey = "com.nucleus.OpenNucleusManual - open nucleus manual - runWorkflowAsService";
      source = "${workflowsDir}/open nucleus manual.workflow";
      thumbnailSymbol = "text.book.closed";
      presentationModes = {
        ContextMenu = true;
        ServicesMenu = true;
        FinderPreview = true;
        TouchBar = true;
      };
    }
    # Optimize PDF presets block, quality-descending and numbered for sort order
    {
      dir = "optimize PDF - (1) default.workflow";
      enablementKey = "com.nucleus.OptimizePDF.default - optimize PDF - (1) default - runWorkflowAsService";
      source = "${workflowsDir}/optimize PDF - (1) default.workflow";
      thumbnailSymbol = "doc.badge.gearshape";
      presentationModes = {
        ContextMenu = true;
        ServicesMenu = true;
        FinderPreview = true;
        TouchBar = true;
      };
    }
    {
      dir = "optimize PDF - (2) prepress.workflow";
      enablementKey = "com.nucleus.OptimizePDF.prepress - optimize PDF - (2) prepress - runWorkflowAsService";
      source = "${workflowsDir}/optimize PDF - (2) prepress.workflow";
      thumbnailSymbol = "doc.badge.gearshape";
      presentationModes = {
        ContextMenu = true;
        ServicesMenu = true;
        FinderPreview = true;
        TouchBar = true;
      };
    }
    {
      dir = "optimize PDF - (3) printer.workflow";
      enablementKey = "com.nucleus.OptimizePDF.printer - optimize PDF - (3) printer - runWorkflowAsService";
      source = "${workflowsDir}/optimize PDF - (3) printer.workflow";
      thumbnailSymbol = "doc.badge.gearshape";
      presentationModes = {
        ContextMenu = true;
        ServicesMenu = true;
        FinderPreview = true;
        TouchBar = true;
      };
    }
    {
      dir = "optimize PDF - (4) ebook.workflow";
      enablementKey = "com.nucleus.OptimizePDF.ebook - optimize PDF - (4) ebook - runWorkflowAsService";
      source = "${workflowsDir}/optimize PDF - (4) ebook.workflow";
      thumbnailSymbol = "doc.badge.gearshape";
      presentationModes = {
        ContextMenu = true;
        ServicesMenu = true;
        FinderPreview = true;
        TouchBar = true;
      };
    }
    {
      dir = "optimize PDF - (5) screen.workflow";
      enablementKey = "com.nucleus.OptimizePDF.screen - optimize PDF - (5) screen - runWorkflowAsService";
      source = "${workflowsDir}/optimize PDF - (5) screen.workflow";
      thumbnailSymbol = "doc.badge.gearshape";
      presentationModes = {
        ContextMenu = true;
        ServicesMenu = true;
        FinderPreview = true;
        TouchBar = true;
      };
    }
    # Alphabetical after "optimize": strip metadata (single unified workflow)
    {
      dir = "strip metadata.workflow";
      enablementKey = "com.nucleus.StripMetadata - strip metadata - runWorkflowAsService";
      source = "${workflowsDir}/strip metadata.workflow";
      thumbnailSymbol = "eraser.line.dashed";
      presentationModes = {
        ContextMenu = true;
        ServicesMenu = true;
        FinderPreview = true;
        TouchBar = true;
      };
    }
  ];
  activationBundle = pkgs.callPackage ../../../../modules/lib/script-tree.nix { };

  # Nix-built open-manual script with the manual path baked in.
  openManualScript = pkgs.writeNucleusShellApplication {
    name = "open-manual";
    runtimeInputs = [ ];
    text = ''
      exec xdg-open "${repoRoot}/src/hosts/MacBook/MANUAL.md"
    '';
  };
in
{
  home.file."Library/Application Support/nucleus/manual.md".source = ../../MANUAL.md;

  # WHY symlink rather than copy: the workflow script needs the manual at a
  # fixed path without NUCLEUS_REPO_ROOT at runtime.
  home.file.".local/lib/nucleus/open-manual" = {
    source = "${openManualScript}/bin/nucleus-open-manual";
    executable = true;
  };

  home.activation.macos-deploy-automator-workflows = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    "${activationBundle}/src/hosts/MacBook/scripts/macos-deploy-automator-workflows.sh" \
      "${pkgs.jq}/bin/jq" \
      '${
        builtins.toJSON (
          map (wf: {
            inherit (wf) dir enablementKey;
            source = "${wf.source}";
            presentationModesDict = mkPresentationModes wf.presentationModes;
          }) currentNucleusWorkflows
        )
      }' \
      "${setWorkflowIcon}" \
      "/usr/bin/defaults" \
      "/usr/bin/mdimport"
  '';
}
