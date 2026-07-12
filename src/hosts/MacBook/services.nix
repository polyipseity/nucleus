# MacBook/services.nix — macOS Quick Actions and App Services for Finder.
#
# Two mechanisms add operations to Finder's context menus:
#
#   Quick Actions (Automator .workflow bundles, preferred):
#     Deployed to ~/Library/Services/, appear in right-click → Quick Actions
#     and the menu bar → Services. More reliable than App Services.
#
#   App Services (.app bundles):
#     Deployed to ~/Applications/ via LaunchServices registration, appear in
#     the Finder menu bar → Services. Also work as Services menu items but
#     are less reliable for context menu placement.
#
# The .app bundle (NucleusManual) is built at evaluation time via a Nix
# derivation (osacompile + PlistBuddy) so the activation script only needs to
# deploy it. The manual file is symlinked to a fixed path via home.file so the
# .app can find it without needing NUCLEUS_REPO_ROOT at runtime.
#
# WHY home.activation instead of home.file:
#   home.file creates a symlink to the Nix store, but macOS LaunchServices does
#   not traverse symlinks when discovering Service provider .app bundles. A
#   home.activation script that deploys the .app on each generation switch
#   guarantees LaunchServices can find it.
#
# WHY compile at evaluation time (.app only):
#   osacompile runs on the target machine during nix build, producing
#   macOS-version-specific .scpt bytecode, but only once per `nucleus-apply`
#   run instead of at every activation. This keeps the same safety property
#   while making the activation script simpler and faster.
{ lib, pkgs, ... }:
let
  nucleusManualAppService =
    pkgs.runCommand "nucleus-manual-app"
      {
        preferLocalBuild = true;
        allowSubstitutes = false;
      }
      ''
        as_src="$TMPDIR/NucleusManual.applescript"
        cat > "$as_src" << 'APPLESCRIPT'
          on open theFiles
            do shell script "open \"$HOME/.local/share/nucleus/manual.md\""
          end open
          on run
            do shell script "open \"$HOME/.local/share/nucleus/manual.md\""
          end run
        APPLESCRIPT

        # osacompile uses CoreServices APIs that fail when writing directly
        # to the Nix store output path (coreFoundationUnknownErr -4960).
        # Compile to a temp dir and copy the result to $out.
        build_dir="$(mktemp -d)"
        /usr/bin/osacompile -l AppleScript -o "$build_dir/NucleusManual.app" "$as_src"

        # Modify Info.plist, then re-sign (osacompile signs the bundle, but
        # PlistBuddy invalidates the signature).
        plist="$build_dir/NucleusManual.app/Contents/Info.plist"
        /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.nucleus.OpenNucleusManual" "$plist"
        /usr/libexec/PlistBuddy -c "Set :CFBundleName Nucleus Manual" "$plist"
        /usr/libexec/PlistBuddy -c "Add :NSServices array" "$plist"
        /usr/libexec/PlistBuddy -c "Add :NSServices:0 dict" "$plist"
        /usr/libexec/PlistBuddy -c "Add :NSServices:0:NSMenuItem dict" "$plist"
        /usr/libexec/PlistBuddy -c "Add :NSServices:0:NSMenuItem:default string open nucleus manual" "$plist"
        /usr/libexec/PlistBuddy -c "Add :NSServices:0:NSMessage string open" "$plist"
        /usr/libexec/PlistBuddy -c "Add :NSServices:0:NSSendTypes array" "$plist"
        /usr/libexec/PlistBuddy -c "Add :NSServices:0:NSSendTypes:0 string public.file-url" "$plist"
        /usr/libexec/PlistBuddy -c "Add :NSServices:0:NSSendTypes:1 string NSFilenamesPboardType" "$plist"
        /usr/libexec/PlistBuddy -c "Add :NSServices:0:NSSendFileTypes array" "$plist"
        /usr/libexec/PlistBuddy -c "Add :NSServices:0:NSSendFileTypes:0 string public.folder" "$plist"
        /usr/libexec/PlistBuddy -c "Add :NSServices:0:NSSendFileTypes:1 string public.data" "$plist"

        /usr/bin/codesign --force -s - "$build_dir/NucleusManual.app"

        mkdir -p "$out"
        cp -R "$build_dir/NucleusManual.app" "$out/"
        rm -rf "$build_dir"
      '';

  # Import centralized daemon refresh helpers for Phase 4.
  daemonRefresh = import ../../modules/macos/daemon-refresh.nix;

  # Per-preset quick action definitions for Ghostscript PDF optimization.
  # Created via Automator GUI, duplicated as files in services/workflows/.
  optimizePdfPresets = [
    "default"
    "ebook"
    "prepress"
    "printer"
    "screen"
  ];

  # Packages all 5 quick action bundles into a single derivation output.
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
            cp -R "${./services/workflows}/optimize PDF - ${preset}.workflow" "$out/"
          '') optimizePdfPresets
        )}
      '';

  # Known list of historically-removed Nucleus app services.
  # When a service is removed, add its metadata here and remove its app dir.
  # The activation script unconditionally removes its NSServicesStatus key
  # and prunes its app directory from disk. Entries can be removed after all
  # machines have applied once after the removal commit.
  removedNucleusAppServices = [
    # Old pre-per-preset single .app bundle (replaced by per-preset apps).
    {
      appDir = "NucleusGSPDFOpt.app";
      bundleId = "com.nucleus.GSPDFOpt";
      menuItem = "gs optimize pdf";
      message = "open";
    }
  ];

  # List of currently deployed app service directories.
  # Used by tests and documentation to track active app services.
  currentNucleusAppServiceDirs = [ "NucleusManual.app" ];

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
  # Symlink the manual to a fixed home path so the .app can find it without
  # needing NUCLEUS_REPO_ROOT at runtime.
  home.file.".local/share/nucleus/manual.md".source = ./MANUAL.md;

  # Deploy Quick Actions and App Services, then register with LaunchServices.
  # home.file can't be used because LaunchServices doesn't traverse symlinks.
  #
  # Self-pruning: before deploying, unconditionally removes NSServicesStatus
  # keys and app/Quick Action directories listed in removedNucleusAppServices
  # and removedNucleusQuickActions. To remove an item: delete its deploy logic
  # and add its metadata to the appropriate removed* list. Cleanup happens
  # automatically on next apply.
  home.activation.deployNucleusServices = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
    APP_DIR="$HOME/Applications"

    # ── Phase 1a: Prune removed app services ───────────────────────────
    ${builtins.concatStringsSep "\n" (
      map (svc: ''
        # Delete NSServicesStatus key for ${svc.appDir} unconditionally.
        /usr/libexec/PlistBuddy -c "Delete :NSServicesStatus:\"${svc.bundleId} - ${svc.menuItem} - ${svc.message}\"" \
          ~/Library/Preferences/pbs.plist 2>/dev/null || true

        app_path="$APP_DIR/${svc.appDir}"
        if [ -d "$app_path" ]; then
          "$LSREGISTER" -u "$app_path" 2>/dev/null || true
          chmod -R +w "$app_path" 2>/dev/null || true
          rm -rf "$app_path"
        fi
      '') removedNucleusAppServices
    )}

    # ── Phase 1b: Prune removed Quick Actions ──────────────────────────
    ${builtins.concatStringsSep "\n" (
      map (qa: ''
        # Delete NSServicesStatus key for ${qa.dir} (old naming convention).
        /usr/libexec/PlistBuddy -c "Delete :NSServicesStatus:\"${qa.enablementKey}\"" \
          ~/Library/Preferences/pbs.plist 2>/dev/null || true

        qa_path="$HOME/Library/Services/${qa.dir}"
        if [ -d "$qa_path" ]; then
          chmod -R +w "$qa_path" 2>/dev/null || true
          rm -rf "$qa_path"
        fi
      '') removedNucleusQuickActions
    )}

    # Force full LaunchServices re-scan to flush stale cache entries.
    # Re-scanned again after all deploys below, so this is a gentle early flush.
    "$LSREGISTER" -R 2>/dev/null || true

    # ── Phase 2: Deploy app services ───────────────────────────────────
    app_path="$APP_DIR/NucleusManual.app"
    store_path="${nucleusManualAppService}/NucleusManual.app"

    mkdir -p "$APP_DIR"
    # Nix store outputs are read-only; strip that before deletion to avoid
    # Permission denied on the next generation switch.
    chmod -R +w "$app_path" 2>/dev/null || true
    rm -rf "$app_path"
    cp -R "$store_path" "$APP_DIR/"
    # Nix store outputs are read-only; make writable so LaunchServices
    # does not silently ignore the app bundle.
    chmod -R u+w "$app_path"

    "$LSREGISTER" -R -f "$app_path" || true

    # Enable the service in NSServicesStatus so it appears in the Services
    # menu and right-click context menu without manual toggling in
    # System Settings > Extensions > Services.
    # Service key format: "<NSBundleIdentifier> - <NSMenuItem.default> - <NSMessage>"
    # Uses presentation_modes dict (macOS 14+) instead of legacy
    # enabled_context_menu/enabled_services_menu booleans.
    enablement_key="com.nucleus.OpenNucleusManual - open nucleus manual - open"
    /usr/bin/defaults write pbs NSServicesStatus -dict-add "$enablement_key" \
      '<dict><key>presentation_modes</key><dict><key>ContextMenu</key><true/><key>ServicesMenu</key><true/><key>FinderPreview</key><true/><key>TouchBar</key><true/></dict></dict>'

    # ── Phase 3: Deploy per-preset OptimizePDF quick actions ────────────
    QUICK_ACTION_DIR="$HOME/Library/Services"
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

    # ── Phase 4: Flush daemon caches so changes take effect immediately ─
    # Without these restarts, cfprefsd, lsd, and pbs all hold stale cached
    # state in process memory. Finder is intentionally excluded here —
    # relaunchDesktopServices (DAG-ordered after writeBoundary) restarts it
    # via launchctl kickstart to preserve window state.
    ${daemonRefresh.refreshServicesMenu}
  '';
}
