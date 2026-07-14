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
#
# WARNING about UTI choice: The UTI "public.pdf" has NEVER existed on macOS.
# Apple's UTI hierarchy defines "public.png", "public.jpeg", "public.html" etc.,
# but NOT "public.pdf". The system assigns "com.adobe.pdf" to all .pdf files.
# Preview.app and all Apple built-in Automator PDF actions use "com.adobe.pdf".
# "public.pdf" is a common AI hallucination — if you see it suggested, reject it.
#
# WHY home.activation instead of home.file:
#   home.file creates a symlink to the Nix store, but Automator .workflow
#   bundles stored as symlinks are not discoverable by the service menu
#   system. This is a required Method 2 (read-only deployment) case;
#   see .agents/instructions/app-config-policy.instructions.md.
#   A home.activation script that copies workflows on each generation
#   switch guarantees they are registered.
#
# WHY home.file for manual.md:
#   The manual.md file is symlinked via home.file so the workflow's shell
#   script can find it at $HOME/.local/share/nucleus/manual.md without needing
#   NUCLEUS_REPO_ROOT at runtime.
{ lib, mkPresentationModes, ... }:
let
  # Base path to committed workflow source directories.
  # Each workflow source is referenced as "${workflowsDir}/<name>.workflow" to
  # avoid parsing issues with spaces in path names.
  workflowsDir = ./automator-workflows;

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
  #   - source: path to copy from
  #   - presentationModes: dict for NSServicesStatus enablement
  #
  # Sorting policy: primary sort is alphabetical by entry name. Exception:
  # the 5 Optimize PDF presets are grouped as a single block and internally
  # sorted quality-descending (default → prepress → printer → ebook → screen).
  # The block is positioned by "optimize PDF" alphabetically. This is the
  # cross-platform convention (same on NixOS and Windows).
  # Deployment order always follows the declared order below. No automatic sorting.
  currentNucleusWorkflows = [
    # Alphabetical before "optimize" — open nucleus manual
    {
      dir = "open nucleus manual.workflow";
      enablementKey = "com.nucleus.OpenNucleusManual - open nucleus manual - runWorkflowAsService";
      source = "${workflowsDir}/open nucleus manual.workflow";
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
      dir = "optimize PDF - default.workflow";
      enablementKey = "com.nucleus.OptimizePDF.default - optimize PDF - default - runWorkflowAsService";
      source = "${workflowsDir}/optimize PDF - default.workflow";
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
  home.file.".local/share/nucleus/manual.md".source = ../MANUAL.md;
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
