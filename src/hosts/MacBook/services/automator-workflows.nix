# MacBook/services/automator-workflows.nix — macOS Automator workflow bundles.
#
# These Automator .workflow bundles appear in the right-click context menu →
# Quick Actions and the menu bar → Services in Finder and other apps. They are
# deployed to ~/Library/Services/.
#
# Each workflow's Info.plist uses NSSendFileTypes with the appropriate UTI:
# - "open nucleus manual.workflow" uses "public.item" (broad scope, available
#   for any file or folder selection — the action ignores input anyway).
# - All "optimize PDF - *.workflow" use "com.adobe.pdf" so the context menu
#   only appears for PDF files.
# - "strip metadata - *.workflow" uses "public.item" (broad scope — the
#   shell script skips unsupported files with warnings internally).
#
# WARNING about UTI choice: The UTI "public.pdf" has NEVER existed on macOS.
# Apple's UTI hierarchy defines "public.png", "public.jpeg", "public.html" etc.,
# but NOT "public.pdf". The system assigns "com.adobe.pdf" to all .pdf files.
# Preview.app and all Apple built-in Automator PDF actions use "com.adobe.pdf".
# "public.pdf" is a common AI hallucination — if you see it suggested, reject it.
#
# WHY: home.activation instead of home.file:
#   home.file creates a symlink to the Nix store, but Automator .workflow
#   bundles stored as symlinks are not discoverable by the service menu
#   system. This is a required Method 2 (read-only deployment) case;
#   see .agents/instructions/app-config-policy.instructions.md.
#   A home.activation script that copies workflows on each generation
#   switch guarantees they are registered.
#
# WHY: home.file for manual.md:
#   The manual.md file is symlinked via home.file so the workflow's shell
#   script can find it at $HOME/Library/Application Support/nucleus/manual.md without needing
#   NUCLEUS_REPO_ROOT at runtime.
#
# SF Symbol icon policy:
#   - Hard rule: always verify SF Symbol names against the macOS private
#     framework — never rely on third-party lists alone. Community lists
#     are often incomplete (e.g. missing entries that the framework includes).
#     Use `.agents/skills/sf-symbols/symbols.txt` for quick grep-based lookup
#     — it is extracted from the framework, not downloaded.
#   - Uniform naming: use the same name for NSIconName (Info.plist) and
#     systemImageName (document.wflow) for cross-surface consistency.
#   - No custom TIFF icons: SF Symbols are resolution-independent and
#     handle dark/light mode natively.
#   - NSBackgroundColorName only affects the Touch Bar — set to "background".
#   - QuickLook/Thumbnail.png is the Get Info window icon (256×256 SF Symbol
#     render), generated at Nix build time via an Objective-C program using
#     AppKit. The `thumbnailSymbol` field below drives generation. Regenerate
#     when changing the symbol name for a workflow.
#   - Finder display: Thumbnail.png alone is not enough. The deploy script
#     calls NSWorkspace.setIcon:forFile:options: (via set-workflow-icon.m)
#     to register the icon with IconServices and set the FinderInfo xattr.
#     This must run at deploy time (not build time) because IconServices
#     caches icons by exact file path.
#   - macOS version floor: check the symbol's introduction year in the
#     framework's name_availability.plist against the host's minimum version.
#   - Known issue: NSIconName can prevent a Quick Action from appearing
#     in the Services menu (Apple Community thread). Current workflows
#     are deployed with it set and are confirmed to appear.
{
  lib,
  pkgs,
  mkPresentationModes,
  repoRoot,
  ...
}:
let
  # Base path to committed workflow source directories.
  # Each workflow source is referenced as "${workflowsDir}/<name>.workflow" to
  # avoid parsing issues with spaces in path names.
  workflowsDir = ./automator-workflows;

  # Baked at eval time from NUCLEUS_REPO_ROOT (set by apply.sh).

  # Path to the ObjC thumbnail generator source.
  thumbnailGenSrc = ../scripts/generate-automator-thumbnails.m;

  # Compiled ObjC program that registers custom Finder icons via NSWorkspace.setIcon:.
  setWorkflowIcon = pkgs.runCommand "set-workflow-icon" { } ''
    ${pkgs.stdenv.cc}/bin/cc -fobjc-arc -fmodules -Wno-deprecated-declarations \
      -framework AppKit -framework Foundation \
      -o "$out" "${../scripts/set-workflow-icon.m}"
  '';

  # Build a workflow bundle with QuickLook/Thumbnail.png generated at build time.
  # Compiles the ObjC SF Symbol renderer with clang (stdenv), runs it headless,
  # and produces a 256×256 PNG. The deploy script copies the entire bundle.
  buildWorkflowWithThumbnail =
    wf:
    wf
    // {
      source = pkgs.runCommand "automator-${builtins.replaceStrings [ " " ] [ "-" ] wf.dir}" { } ''
        cp -r "${wf.source}" "$out"
        chmod -R u+w "$out"
        mkdir -p "$out/Contents/QuickLook"
        ${pkgs.stdenv.cc}/bin/cc -fobjc-arc -fmodules -framework AppKit -framework Foundation \
          -o render_symbol "${thumbnailGenSrc}"
        ./render_symbol "${wf.thumbnailSymbol}" "$out/Contents/QuickLook/Thumbnail.png"
      '';
    };

  # Currently deployed Automator workflows. Add new workflows here.
  # Each entry has:
  #   - dir: workflow directory name in ~/Library/Services/
  #   - enablementKey: key for NSServicesStatus enablement
  #   - source: path to copy from (before thumbnail overlay)
  #   - thumbnailSymbol: SF Symbol name for QuickLook/Thumbnail.png
  #   - presentationModes: dict for NSServicesStatus enablement
  #
  # Sorting policy: primary sort is alphabetical by entry name. Exceptions:
  # - the 5 Optimize PDF presets are grouped as a single block and internally
  #   sorted quality-descending (default → prepress → printer → ebook → screen).
  # Each block is positioned by its primary name alphabetically. This is the
  # cross-platform convention (same on NixOS and Windows).
  # Deployment order always follows the declared order below. No automatic sorting.
  currentNucleusWorkflows = map buildWorkflowWithThumbnail [
    # Alphabetical before "optimize" — open nucleus manual
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
    # Alphabetical between "open" and "optimize" — strip metadata (single unified workflow)
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
    # Optimize PDF presets block — quality-descending, internally sorted
    {
      dir = "optimize PDF - default.workflow";
      enablementKey = "com.nucleus.OptimizePDF.default - optimize PDF - default - runWorkflowAsService";
      source = "${workflowsDir}/optimize PDF - default.workflow";
      thumbnailSymbol = "doc.badge.gearshape";
      presentationModes = {
        ContextMenu = true;
        ServicesMenu = true;
        FinderPreview = true;
        TouchBar = true;
      };
    }
    {
      dir = "optimize PDF - prepress.workflow";
      enablementKey = "com.nucleus.OptimizePDF.prepress - optimize PDF - prepress - runWorkflowAsService";
      source = "${workflowsDir}/optimize PDF - prepress.workflow";
      thumbnailSymbol = "doc.badge.gearshape";
      presentationModes = {
        ContextMenu = true;
        ServicesMenu = true;
        FinderPreview = true;
        TouchBar = true;
      };
    }
    {
      dir = "optimize PDF - printer.workflow";
      enablementKey = "com.nucleus.OptimizePDF.printer - optimize PDF - printer - runWorkflowAsService";
      source = "${workflowsDir}/optimize PDF - printer.workflow";
      thumbnailSymbol = "doc.badge.gearshape";
      presentationModes = {
        ContextMenu = true;
        ServicesMenu = true;
        FinderPreview = true;
        TouchBar = true;
      };
    }
    {
      dir = "optimize PDF - ebook.workflow";
      enablementKey = "com.nucleus.OptimizePDF.ebook - optimize PDF - ebook - runWorkflowAsService";
      source = "${workflowsDir}/optimize PDF - ebook.workflow";
      thumbnailSymbol = "doc.badge.gearshape";
      presentationModes = {
        ContextMenu = true;
        ServicesMenu = true;
        FinderPreview = true;
        TouchBar = true;
      };
    }
    {
      dir = "optimize PDF - screen.workflow";
      enablementKey = "com.nucleus.OptimizePDF.screen - optimize PDF - screen - runWorkflowAsService";
      source = "${workflowsDir}/optimize PDF - screen.workflow";
      thumbnailSymbol = "doc.badge.gearshape";
      presentationModes = {
        ContextMenu = true;
        ServicesMenu = true;
        FinderPreview = true;
        TouchBar = true;
      };
    }
  ];
  activationBundle = pkgs.callPackage ../../../modules/lib/script-tree.nix { };

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
  home.file."Library/Application Support/nucleus/manual.md".source = ../MANUAL.md;

  # CLI entry: `nucleus-open-manual` in ~/.local/lib/nucleus/open-manual.
  # Uses the shared open-host-manual.sh with the manual path as positional arg.
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
      "${setWorkflowIcon}"
  '';
}
