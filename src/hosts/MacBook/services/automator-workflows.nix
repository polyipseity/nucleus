# MacBook/services/automator-workflows.nix — macOS Automator workflow bundles.
#
# These Automator .workflow bundles appear in the right-click context menu →
# Quick Actions and the menu bar → Services in Finder and other apps. They are
# deployed to ~/Library/Services/.
#
# WHY home.activation instead of home.file:
#   home.file creates a symlink to the Nix store, but Automator .workflow
#   bundles stored as symlinks are not discoverable by the service menu
#   system. A home.activation script that copies workflows on each generation
#   switch guarantees they are registered.
{
  lib,
  pkgs,
  mkPresentationModes,
  ...
}:
let
  # ── Derivation: bundle all workflow directories ───────────────────────
  # Packages all 5 Automator workflow bundles into a single derivation output.
  # Each bundle is a committed .workflow directory in services/automator-workflows/,
  # copied verbatim (no build-time processing).
  nucleusOptimizePdfWorkflows =
    pkgs.runCommand "nucleus-gs-pdf-opt-workflows"
      {
        preferLocalBuild = true;
        allowSubstitutes = false;
      }
      ''
        mkdir -p "$out"
        cp -R "${./automator-workflows}/optimize PDF - default.workflow" "$out/"
        cp -R "${./automator-workflows}/optimize PDF - printer.workflow" "$out/"
        cp -R "${./automator-workflows}/optimize PDF - prepress.workflow" "$out/"
        cp -R "${./automator-workflows}/optimize PDF - ebook.workflow" "$out/"
        cp -R "${./automator-workflows}/optimize PDF - screen.workflow" "$out/"
      '';

  # Known list of historically-removed Automator workflows (old workflow naming).
  # When a workflow is removed, add its metadata here and delete its
  # workflow directory and pbs enablement key.
  # Entries can be removed after all machines have applied once after
  # the removal commit.
  removedNucleusWorkflows = [
    {
      dir = "OptimizePDF-default.workflow";
      bundleId = "com.nucleus.OptimizePDF-default";
      enablementKey = "com.nucleus.OptimizePDF-default - optimize PDF - default - runWorkflowAsService";
    }
    {
      dir = "OptimizePDF-ebook.workflow";
      bundleId = "com.nucleus.OptimizePDF-ebook";
      enablementKey = "com.nucleus.OptimizePDF-ebook - optimize PDF - ebook - runWorkflowAsService";
    }
    {
      dir = "OptimizePDF-prepress.workflow";
      bundleId = "com.nucleus.OptimizePDF-prepress";
      enablementKey = "com.nucleus.OptimizePDF-prepress - optimize PDF - prepress - runWorkflowAsService";
    }
    {
      dir = "OptimizePDF-printer.workflow";
      bundleId = "com.nucleus.OptimizePDF-printer";
      enablementKey = "com.nucleus.OptimizePDF-printer - optimize PDF - printer - runWorkflowAsService";
    }
    {
      dir = "OptimizePDF-screen.workflow";
      bundleId = "com.nucleus.OptimizePDF-screen";
      enablementKey = "com.nucleus.OptimizePDF-screen - optimize PDF - screen - runWorkflowAsService";
    }
    # Legacy keys from historical naming conventions.
    # Entries without dir skip directory removal (only delete NSServicesStatus key).
    {
      # Initial GSPDFOpt naming — replaced by per-preset workflows.
      enablementKey = "com.nucleus.GSPDFOpt-default - Optimize PDF - default - runWorkflowAsService";
    }
    { enablementKey = "com.nucleus.GSPDFOpt-ebook - Optimize PDF - ebook - runWorkflowAsService"; }
    {
      enablementKey = "com.nucleus.GSPDFOpt-prepress - Optimize PDF - prepress - runWorkflowAsService";
    }
    { enablementKey = "com.nucleus.GSPDFOpt-printer - Optimize PDF - printer - runWorkflowAsService"; }
    { enablementKey = "com.nucleus.GSPDFOpt-screen - Optimize PDF - screen - runWorkflowAsService"; }
    {
      # (null) bundle-ID period (ca741218..3702ef93) — before workflow Info.plist
      # had CFBundleIdentifier set.
      enablementKey = "(null) - optimize PDF - default - runWorkflowAsService";
    }
    { enablementKey = "(null) - optimize PDF - ebook - runWorkflowAsService"; }
    { enablementKey = "(null) - optimize PDF - prepress - runWorkflowAsService"; }
    { enablementKey = "(null) - optimize PDF - printer - runWorkflowAsService"; }
    { enablementKey = "(null) - optimize PDF - screen - runWorkflowAsService"; }
  ];

  # Currently deployed Automator workflows. Add new workflows here.
  # Each entry has:
  #   - dir: workflow directory name in ~/Library/Services/
  #   - enablementKey: key for NSServicesStatus enablement
  #   - source: derivation path to copy from
  #   - presentationModes: dict for NSServicesStatus enablement
  #
  # Sorting policy: manually maintained in quality-descending order (default → prepress → printer → ebook → screen).
  # This is the cross-platform Optimize PDF ordering (same as NixOS and Windows).
  # Deployment order always follows the declared order below. No automatic sorting.
  currentNucleusWorkflows = [
    {
      dir = "optimize PDF - default.workflow";
      enablementKey = "com.nucleus.OptimizePDF.default - optimize PDF - default - runWorkflowAsService";
      source = "${nucleusOptimizePdfWorkflows}/optimize PDF - default.workflow";
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
      source = "${nucleusOptimizePdfWorkflows}/optimize PDF - prepress.workflow";
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
      source = "${nucleusOptimizePdfWorkflows}/optimize PDF - printer.workflow";
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
      source = "${nucleusOptimizePdfWorkflows}/optimize PDF - ebook.workflow";
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
      source = "${nucleusOptimizePdfWorkflows}/optimize PDF - screen.workflow";
      presentationModes = {
        ContextMenu = true;
        ServicesMenu = true;
        FinderPreview = true;
        TouchBar = true;
      };
    }
  ];
in
{
  home.activation.deployNucleusAutomatorWorkflows = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    SERVICES_DIR="$HOME/Library/Services"

    # ── Phase 1b: Prune removed Automator workflows ────────────────────
    # First pass: delete all NSServicesStatus keys (entries may or may not have dir).
    ${builtins.concatStringsSep "\n" (
      map (wf: ''
        /usr/libexec/PlistBuddy -c "Delete :NSServicesStatus:\"${wf.enablementKey}\"" \
          ~/Library/Preferences/pbs.plist 2>/dev/null || true  # undoc-supp: key may not exist on first apply
      '') removedNucleusWorkflows
    )}
    # Second pass: remove workflow dirs for entries that have one.
    ${builtins.concatStringsSep "\n" (
      map (wf: ''
        wf_path="$SERVICES_DIR/${wf.dir}"
        if [ -d "$wf_path" ]; then
          chmod -R +w "$wf_path" 2>/dev/null || true  # undoc-supp: dir may not exist on first apply
          rm -rf "$wf_path"
        fi
      '') (builtins.filter (wf: wf ? dir) removedNucleusWorkflows)
    )}

    # ── Phase 3: Deploy Automator workflows (in declaration order) ────
    ${builtins.concatStringsSep "\n" (
      map (wf: ''
        wf_dir="$SERVICES_DIR/${wf.dir}"
        store_path="${wf.source}"
        mkdir -p "$SERVICES_DIR"
        chmod -R +w "$wf_dir" 2>/dev/null || true  # undoc-supp: dir may not exist on first apply
        rm -rf "$wf_dir"
        cp -R "$store_path" "$SERVICES_DIR/"
        # Enable in presentation_modes format (macOS 14+).
        # CFBundleIdentifier is set in each workflow's Info.plist.
        enablement_key="${wf.enablementKey}"
        /usr/bin/defaults write pbs NSServicesStatus -dict-add "$enablement_key" \
          '<dict><key>presentation_modes</key>${mkPresentationModes wf.presentationModes}</dict>'
      '') currentNucleusWorkflows
    )}
  '';
}
