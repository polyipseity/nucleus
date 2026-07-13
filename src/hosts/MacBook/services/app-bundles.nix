# MacBook/services/app-bundles.nix — macOS App bundles deployed via LaunchServices.
#
# These .app bundles appear in the Finder menu bar → Services. They are
# deployed to ~/Applications/ via LaunchServices registration.
# Less reliable than Quick Actions for context menu placement but work
# reliably in the Services menu.
#
# The .app bundle (NucleusManual) is built at evaluation time via a Nix
# derivation (osacompile + PlistBuddy) so the activation script only needs
# to deploy it. The manual file is symlinked to a fixed path via home.file
# so the .app can find it without needing NUCLEUS_REPO_ROOT at runtime.
#
# WHY home.activation instead of home.file:
#   home.file creates a symlink to the Nix store, but macOS LaunchServices
#   does not traverse symlinks when discovering Service provider .app
#   bundles. A home.activation script that deploys the .app on each
#   generation switch guarantees LaunchServices can find it.
#
# WHY compile at evaluation time:
#   osacompile runs during nix build, producing macOS-version-specific
#   .scpt bytecode, but only once per `nucleus-apply` run. This makes the
#   activation script simpler and faster while keeping build-time safety.
{
  lib,
  pkgs,
  mkPresentationModes,
  ...
}:
let
  nucleusManualAppBundle =
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

  # Known list of historically-removed Nucleus app bundles.
  # When a bundle is removed, add its metadata here and remove its app dir.
  # The activation script unconditionally removes its NSServicesStatus key
  # and prunes its app directory from disk. Entries can be removed after all
  # machines have applied once after the removal commit.
  removedNucleusAppBundles = [
    # Old pre-per-preset single .app bundle (replaced by per-preset Automator
    # workflows).
    {
      appDir = "NucleusGSPDFOpt.app";
      bundleId = "com.nucleus.GSPDFOpt";
      menuItem = "gs optimize pdf";
      message = "open";
    }
  ];

  # Currently deployed app bundles. Add new bundles here.
  # Each entry has:
  #   - appDir: directory name in ~/Applications/
  #   - bundleId: CFBundleIdentifier (used for NSServicesStatus key)
  #   - menuItem: NSMenuItem.default (used for NSServicesStatus key)
  #   - message: NSMessage (used for NSServicesStatus key)
  #   - source: derivation path to copy from
  #   - presentationModes: dict for NSServicesStatus enablement
  #
  # Sorting policy: alphabetical by appDir by default. Delegation order
  # always follows the sorted list. If an exception is needed, document
  # it below with rationale.
  currentNucleusAppBundles = [
    {
      appDir = "NucleusManual.app";
      bundleId = "com.nucleus.OpenNucleusManual";
      menuItem = "open nucleus manual";
      message = "open";
      source = "${nucleusManualAppBundle}/NucleusManual.app";
      presentationModes = {
        ContextMenu = true;
        ServicesMenu = true;
        FinderPreview = true;
        TouchBar = true;
      };
    }
  ];

  # List of currently deployed app bundle directories (derived).
  # Used by tests and documentation to track active app bundles.
  currentNucleusAppBundleDirs = map (svc: svc.appDir) currentNucleusAppBundles;

  # Sort alphabetically by appDir for deterministic deployment.
  sortedCurrentNucleusAppBundles = builtins.sort (a: b: a.appDir < b.appDir) currentNucleusAppBundles;
in
{
  home.file.".local/share/nucleus/manual.md".source = ../MANUAL.md;

  home.activation.deployNucleusAppBundles = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
    APP_DIR="$HOME/Applications"

    # ── Phase 1a: Prune removed app bundles ───────────────────────────
    ${builtins.concatStringsSep "\n" (
      map (svc: ''
        # Delete NSServicesStatus key for ${svc.appDir} unconditionally.
        /usr/libexec/PlistBuddy -c "Delete :NSServicesStatus:\"${svc.bundleId} - ${svc.menuItem} - ${svc.message}\"" \
          ~/Library/Preferences/pbs.plist 2>/dev/null || true  # undoc-supp: key may not exist on first apply

        app_path="$APP_DIR/${svc.appDir}"
        if [ -d "$app_path" ]; then
          "$LSREGISTER" -u "$app_path" 2>/dev/null || true  # undoc-supp: app may not be deployed yet
          chmod -R +w "$app_path" 2>/dev/null || true  # undoc-supp: dir may not exist on first apply
          rm -rf "$app_path"
        fi
      '') removedNucleusAppBundles
    )}

    # ── Phase 2: Deploy app bundles ───────────────────────────────────
    ${builtins.concatStringsSep "\n" (
      map (svc: ''
        app_path="$APP_DIR/${svc.appDir}"
        store_path="${svc.source}"

        mkdir -p "$APP_DIR"
        # Nix store outputs are read-only; strip that before deletion to avoid
        # Permission denied on the next generation switch.
        chmod -R +w "$app_path" 2>/dev/null || true  # undoc-supp: dir may not exist on first apply
        rm -rf "$app_path"
        cp -R "$store_path" "$APP_DIR/"

        "$LSREGISTER" -R -f "$app_path" || true  # undoc-supp: LaunchServices may reject unsigned bundles; not fatal

        # Enable the service in NSServicesStatus so it appears in the Services
        # menu and right-click context menu without manual toggling in
        # System Settings > Extensions > Services.
        # Service key format: "<NSBundleIdentifier> - <NSMenuItem.default> - <NSMessage>"
        # Uses presentation_modes dict (macOS 14+) instead of legacy
        # enabled_context_menu/enabled_services_menu booleans.
        enablement_key="${svc.bundleId} - ${svc.menuItem} - ${svc.message}"
        /usr/bin/defaults write pbs NSServicesStatus -dict-add "$enablement_key" \
          '<dict><key>presentation_modes</key>${mkPresentationModes svc.presentationModes}</dict>'
      '') sortedCurrentNucleusAppBundles
    )}
  '';
}
