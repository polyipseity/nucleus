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
{ lib, pkgs, ... }:
let
  # Per-preset Quick Action definitions for Ghostscript PDF optimization.
  # Created via Automator GUI, duplicated as files in services/workflows/.
  optimizePdfPresets = [
    "default"
    "ebook"
    "prepress"
    "printer"
    "screen"
  ];

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
        ${builtins.concatStringsSep "\n" (
          map (preset: ''
            cp -R "${./workflows}/optimize PDF - ${preset}.workflow" "$out/"
          '') optimizePdfPresets
        )}
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
in
{
  home.activation.deployNucleusQuickActions = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    QUICK_ACTION_DIR="$HOME/Library/Services"

    # ── Phase 1b: Prune removed Quick Actions ──────────────────────────
    ${builtins.concatStringsSep "\n" (
      map (qa: ''
        # Delete NSServicesStatus key for ${qa.dir} (old naming convention).
        /usr/libexec/PlistBuddy -c "Delete :NSServicesStatus:\"${qa.enablementKey}\"" \
          ~/Library/Preferences/pbs.plist 2>/dev/null || true

        qa_path="$QUICK_ACTION_DIR/${qa.dir}"
        if [ -d "$qa_path" ]; then
          chmod -R +w "$qa_path" 2>/dev/null || true
          rm -rf "$qa_path"
        fi
      '') removedNucleusQuickActions
    )}

    # ── Phase 3: Deploy per-preset OptimizePDF Quick Actions ────────────
    ${builtins.concatStringsSep "\n" (
      map (preset: ''
        wf_dir="$QUICK_ACTION_DIR/optimize PDF - ${preset}.workflow"
        store_path="${nucleusOptimizePdfQuickActions}/optimize PDF - ${preset}.workflow"
        mkdir -p "$QUICK_ACTION_DIR"
        chmod -R +w "$wf_dir" 2>/dev/null || true
        rm -rf "$wf_dir"
        cp -R "$store_path" "$QUICK_ACTION_DIR/"
        chmod -R u+w "$wf_dir"
        # Remove stale legacy entries (pre-macOS 14 format).
        # Uses PlistBuddy instead of `defaults delete` because `defaults`
        # cannot parse keys containing spaces or dots as sub-key paths.
        for legacy_key in \
          "com.nucleus.GSPDFOpt-${preset} - Optimize PDF - ${preset} - runWorkflowAsService" \
          "com.nucleus.OptimizePDF-${preset} - optimize PDF - ${preset} - runWorkflowAsService"; do
          /usr/libexec/PlistBuddy -c "Delete :NSServicesStatus:\"$legacy_key\"" \
            ~/Library/Preferences/pbs.plist 2>/dev/null || true
        done
        # Enable in presentation_modes format (macOS 14+).
        # CFBundleIdentifier is set in each workflow's Info.plist.
        enablement_key="com.nucleus.OptimizePDF.${preset} - optimize PDF - ${preset} - runWorkflowAsService"
        /usr/bin/defaults write pbs NSServicesStatus -dict-add "$enablement_key" \
          '<dict><key>presentation_modes</key><dict><key>ContextMenu</key><true/><key>ServicesMenu</key><true/><key>FinderPreview</key><true/><key>TouchBar</key><true/></dict></dict>'
      '') optimizePdfPresets
    )}
  '';
}
