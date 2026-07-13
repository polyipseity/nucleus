# MacBook/services/quick-actions.nix — macOS Quick Actions (Automator .workflow bundles).
#
# Quick Actions appear in the right-click context menu → Quick Actions and
# the menu bar → Services in Finder and other apps. They are Automator
# .workflow bundles deployed to ~/Library/Services/.
#
# WHY home.activation instead of home.file:
#   home.file creates a symlink to the Nix store, but Quick Actions stored
#   as symlinks are not discoverable by the service menu system. A
#   home.activation script that copies workflows on each generation switch
#   guarantees they are registered.
{
  lib,
  pkgs,
  mkPresentationModes,
  ...
}:
let
  # ── Derivation: bundle all workflow directories ───────────────────────
  # Packages all 5 Quick Action bundles into a single derivation output.
  # Each bundle is a committed .workflow directory in services/workflows/,
  # copied verbatim (no build-time processing).
  nucleusOptimizePdfQuickActions =
    pkgs.runCommand "nucleus-gs-pdf-opt-workflows"
      {
        preferLocalBuild = true;
        allowSubstitutes = false;
      }
      ''
        mkdir -p "$out"
        cp -R "${./workflows}/optimize PDF - default.workflow" "$out/"
        cp -R "${./workflows}/optimize PDF - printer.workflow" "$out/"
        cp -R "${./workflows}/optimize PDF - prepress.workflow" "$out/"
        cp -R "${./workflows}/optimize PDF - ebook.workflow" "$out/"
        cp -R "${./workflows}/optimize PDF - screen.workflow" "$out/"
      '';

  # Known list of historically-removed Quick Actions (old workflow naming).
  # When a Quick Action is removed, add its metadata here and delete its
  # workflow directory and pbs enablement key.
  # Entries can be removed after all machines have applied once after
  # the removal commit.
  removedNucleusQuickActions = [
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
  ];

  # Currently deployed Quick Actions. Add new actions here.
  # Each entry has:
  #   - dir: workflow directory name in ~/Library/Services/
  #   - enablementKey: key for NSServicesStatus enablement
  #   - source: derivation path to copy from
  #   - legacyKeys: list of old NSServicesStatus keys to remove
  #   - presentationModes: dict for NSServicesStatus enablement
  #
  # Sorting policy: alphabetical by dir by default.
  # Exception: Optimize PDF actions are ordered by quality descending
  # (prepress > printer > ebook > screen), with "default" always first.
  # Deployment order always follows the declared order below.
  currentNucleusQuickActions = [
    {
      dir = "optimize PDF - default.workflow";
      enablementKey = "com.nucleus.OptimizePDF.default - optimize PDF - default - runWorkflowAsService";
      source = "${nucleusOptimizePdfQuickActions}/optimize PDF - default.workflow";
      legacyKeys = [
        "com.nucleus.GSPDFOpt-default - Optimize PDF - default - runWorkflowAsService"
        "com.nucleus.OptimizePDF-default - optimize PDF - default - runWorkflowAsService"
      ];
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
      source = "${nucleusOptimizePdfQuickActions}/optimize PDF - prepress.workflow";
      legacyKeys = [
        "com.nucleus.GSPDFOpt-prepress - Optimize PDF - prepress - runWorkflowAsService"
        "com.nucleus.OptimizePDF-prepress - optimize PDF - prepress - runWorkflowAsService"
      ];
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
      source = "${nucleusOptimizePdfQuickActions}/optimize PDF - printer.workflow";
      legacyKeys = [
        "com.nucleus.GSPDFOpt-printer - Optimize PDF - printer - runWorkflowAsService"
        "com.nucleus.OptimizePDF-printer - optimize PDF - printer - runWorkflowAsService"
      ];
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
      source = "${nucleusOptimizePdfQuickActions}/optimize PDF - ebook.workflow";
      legacyKeys = [
        "com.nucleus.GSPDFOpt-ebook - Optimize PDF - ebook - runWorkflowAsService"
        "com.nucleus.OptimizePDF-ebook - optimize PDF - ebook - runWorkflowAsService"
      ];
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
      source = "${nucleusOptimizePdfQuickActions}/optimize PDF - screen.workflow";
      legacyKeys = [
        "com.nucleus.GSPDFOpt-screen - Optimize PDF - screen - runWorkflowAsService"
        "com.nucleus.OptimizePDF-screen - optimize PDF - screen - runWorkflowAsService"
      ];
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
  home.activation.deployNucleusQuickActions = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    QUICK_ACTION_DIR="$HOME/Library/Services"

    # ── Phase 1b: Prune removed Quick Actions ──────────────────────────
    ${builtins.concatStringsSep "\n" (
      map (qa: ''
        # Delete NSServicesStatus key for ${qa.dir} (old naming convention).
        /usr/libexec/PlistBuddy -c "Delete :NSServicesStatus:\"${qa.enablementKey}\"" \
          ~/Library/Preferences/pbs.plist 2>/dev/null || true  # WHY: key may not exist on first apply

        qa_path="$QUICK_ACTION_DIR/${qa.dir}"
        if [ -d "$qa_path" ]; then
          chmod -R +w "$qa_path" 2>/dev/null || true  # WHY: dir may not exist on first apply
          rm -rf "$qa_path"
        fi
      '') removedNucleusQuickActions
    )}

    # ── Phase 3: Deploy Quick Actions ──────────────────────────────────
    ${builtins.concatStringsSep "\n" (
      map (qa: ''
        wf_dir="$QUICK_ACTION_DIR/${qa.dir}"
        store_path="${qa.source}"
        mkdir -p "$QUICK_ACTION_DIR"
        chmod -R +w "$wf_dir" 2>/dev/null || true  # WHY: dir may not exist on first apply
        rm -rf "$wf_dir"
        cp -R "$store_path" "$QUICK_ACTION_DIR/"
        # Remove stale legacy entries (pre-macOS 14 format).
        # Uses PlistBuddy instead of `defaults delete` because `defaults`
        # cannot parse keys containing spaces or dots as sub-key paths.
        for legacy_key in ${builtins.concatStringsSep " " (map (k: ''"${k}"'') qa.legacyKeys)}; do
          /usr/libexec/PlistBuddy -c "Delete :NSServicesStatus:\"$legacy_key\"" \
            ~/Library/Preferences/pbs.plist 2>/dev/null || true  # WHY: key may not exist after previous cleanup
        done
        # Enable in presentation_modes format (macOS 14+).
        # CFBundleIdentifier is set in each workflow's Info.plist.
        enablement_key="${qa.enablementKey}"
        /usr/bin/defaults write pbs NSServicesStatus -dict-add "$enablement_key" \
          '<dict><key>presentation_modes</key>${mkPresentationModes qa.presentationModes}</dict>'
      '') currentNucleusQuickActions
    )}
  '';
}
