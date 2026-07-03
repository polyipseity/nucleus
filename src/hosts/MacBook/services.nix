# MacBook/services.nix — macOS Services (right-click context menu items) for Finder.
#
# macOS Services let apps register operations that appear in other apps' menus,
# including Finder's right-click context menu under Services → [Service Name].
# An app bundle with NSServices in its Info.plist is deployed to ~/Applications/,
# then registered with LaunchServices so the service appears in Finder's Services
# menu.
#
# The .app bundle is built at evaluation time via a Nix derivation (osacompile +
# PlistBuddy) so the activation script only needs to deploy it. The manual file
# is symlinked to a fixed path via home.file so the .app can find it without
# needing NUCLEUS_REPO_ROOT at runtime.
#
# WHY home.activation instead of home.file:
#   home.file creates a symlink to the Nix store, but macOS LaunchServices does
#   not traverse symlinks when discovering Service provider apps. A
#   home.activation script that deploys the .app on each generation switch
#   guarantees LaunchServices can find it.
#
# WHY compile at evaluation time:
#   osacompile runs on the target machine during nix build, producing
#   macOS-version-specific .scpt bytecode, but only once per `nucleus-apply`
#   run instead of at every activation. This keeps the same safety property
#   while making the activation script simpler and faster.
{ lib, pkgs, ... }:
let
  nucleusManualApp =
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

  # Generate a per-preset .app bundle for Ghostscript PDF optimization.
  # Each preset gets its own .app so it can have a distinct menu label.
  gsPdfOptPresets = [
    "default"
    "ebook"
    "prepress"
    "printer"
    "screen"
  ];

  mkGSPDFOptApp =
    preset:
    pkgs.runCommand "nucleus-gs-pdf-opt-${preset}-app"
      {
        preferLocalBuild = true;
        allowSubstitutes = false;
      }
      ''
        as_src="$TMPDIR/NucleusGSPDFOpt.applescript"
        cat > "$as_src" << APPLESCRIPT
          on open theFiles
            repeat with theFile in theFiles
              do shell script "export PATH=\"\$HOME/.nix-profile/bin:/etc/profiles/per-user/\$USER/bin:/usr/local/bin:/usr/bin:/bin\" && nucleus-gs-pdf-opt --preset ${preset} " & quoted form of POSIX path of theFile
            end repeat
          end open
          on run
            -- No default action without files
          end run
        APPLESCRIPT

        build_dir="$(mktemp -d)"
        /usr/bin/osacompile -l AppleScript -o "$build_dir/NucleusGSPDFOpt-${preset}.app" "$as_src"

        plist="$build_dir/NucleusGSPDFOpt-${preset}.app/Contents/Info.plist"
        /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.nucleus.GSPDFOpt-${preset}" "$plist"
        /usr/libexec/PlistBuddy -c "Set :CFBundleName Optimize PDF - ${preset}" "$plist"
        /usr/libexec/PlistBuddy -c "Add :NSServices array" "$plist"
        /usr/libexec/PlistBuddy -c "Add :NSServices:0 dict" "$plist"
        /usr/libexec/PlistBuddy -c "Add :NSServices:0:NSMenuItem dict" "$plist"
        /usr/libexec/PlistBuddy -c "Add :NSServices:0:NSMenuItem:default string optimize pdf - ${preset}" "$plist"
        /usr/libexec/PlistBuddy -c "Add :NSServices:0:NSMessage string open" "$plist"
        /usr/libexec/PlistBuddy -c "Add :NSServices:0:NSSendTypes array" "$plist"
        /usr/libexec/PlistBuddy -c "Add :NSServices:0:NSSendTypes:0 string public.file-url" "$plist"
        /usr/libexec/PlistBuddy -c "Add :NSServices:0:NSSendTypes:1 string NSFilenamesPboardType" "$plist"
        /usr/libexec/PlistBuddy -c "Add :NSServices:0:NSSendFileTypes array" "$plist"
        /usr/libexec/PlistBuddy -c "Add :NSServices:0:NSSendFileTypes:0 string com.adobe.pdf" "$plist"

        /usr/bin/codesign --force -s - "$build_dir/NucleusGSPDFOpt-${preset}.app"

        mkdir -p "$out"
        cp -R "$build_dir/NucleusGSPDFOpt-${preset}.app" "$out/"
        rm -rf "$build_dir"
      '';

  nucleusGSPDFOptApps = builtins.listToAttrs (
    map (p: {
      name = p;
      value = mkGSPDFOptApp p;
    }) gsPdfOptPresets
  );

  # Import centralized daemon refresh helpers for Phase 4.
  daemonRefresh = import ../../modules/macos/daemon-refresh.nix;

  # Known list of current Nucleus service .app directory names.
  # Used for deterministic deployment.
  currentNucleusAppDirs = [
    "NucleusManual.app"
  ]
  ++ map (preset: "NucleusGSPDFOpt-${preset}.app") gsPdfOptPresets;

  # Known list of historically-removed Nucleus services.
  # When a service is removed, add its metadata here and remove its app dir
  # from currentNucleusAppDirs. The activation script unconditionally removes
  # its NSServicesStatus key and prunes its app directory from disk. Entries
  # can be removed after all machines have applied once after the removal commit.
  removedNucleusServices = [
    {
      appDir = "NucleusGSPDFOpt.app";
      bundleId = "com.nucleus.GSPDFOpt";
      menuItem = "gs optimize pdf";
      message = "open";
    }
  ];
in
{
  # Symlink the manual to a fixed home path so the .app can find it without
  # needing NUCLEUS_REPO_ROOT at runtime.
  home.file.".local/share/nucleus/manual.md".source = ./MANUAL.md;

  # Deploy all Nucleus .app bundles and register with LaunchServices.
  # home.file can't be used because LaunchServices doesn't traverse symlinks.
  #
  # Self-pruning: before deploying, unconditionally removes NSServicesStatus
  # keys and app directories listed in removedNucleusServices. To remove a
  # service: delete its deploy logic and add its metadata to
  # removedNucleusServices. The cleanup happens automatically on next apply.
  home.activation.deployNucleusServices = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
    APP_DIR="$HOME/Applications"

    # ── Phase 1: Prune historically-removed services ────────────────────
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
      '') removedNucleusServices
    )}

    # Force full LaunchServices re-scan to flush stale cache entries.
    # Phase 4's -kill -domain user is stronger and runs after all deploys,
    # so this call is redundant but kept as a gentle early flush.
    "$LSREGISTER" -R 2>/dev/null || true

    # ── Phase 2: Deploy NucleusManual ──────────────────────────────────
    app_path="$APP_DIR/NucleusManual.app"
    store_path="${nucleusManualApp}/NucleusManual.app"

    mkdir -p "$APP_DIR"
    # Nix store outputs are read-only; strip that before deletion to avoid
    # Permission denied on the next generation switch.
    chmod -R +w "$app_path" 2>/dev/null || true
    rm -rf "$app_path"
    cp -R "$store_path" "$APP_DIR/"

    "$LSREGISTER" -R -f "$app_path" || true

    # Enable the service in NSServicesStatus so it appears in the Services
    # menu without manual toggling in System Settings > Extensions > Services.
    # Service key format: "<NSBundleIdentifier> - <NSMenuItem.default> - <NSMessage>"
    enablement_key="com.nucleus.OpenNucleusManual - open nucleus manual - open"
    /usr/bin/defaults write pbs NSServicesStatus -dict-add "$enablement_key" \
      '<dict><key>enabled_context_menu</key><true/><key>enabled_services_menu</key><true/></dict>'

    # ── Phase 3: Deploy GSPDFOpt per-preset apps ───────────────────────
    ${builtins.concatStringsSep "\n" (
      map (preset: ''
        app_path="$APP_DIR/NucleusGSPDFOpt-${preset}.app"
        store_path="${nucleusGSPDFOptApps.${preset}}/NucleusGSPDFOpt-${preset}.app"

        mkdir -p "$APP_DIR"
        chmod -R +w "$app_path" 2>/dev/null || true
        rm -rf "$app_path"
        cp -R "$store_path" "$APP_DIR/"

        "$LSREGISTER" -R -f "$app_path" || true

        enablement_key="com.nucleus.GSPDFOpt-${preset} - optimize pdf - ${preset} - open"
        /usr/bin/defaults write pbs NSServicesStatus -dict-add "$enablement_key" \
          '<dict><key>enabled_context_menu</key><true/><key>enabled_services_menu</key><true/></dict>'
      '') gsPdfOptPresets
    )}

    # ── Phase 4: Flush daemon caches so changes take effect immediately ─
    # Without these restarts, cfprefsd, lsd, and pbs all hold stale cached
    # state in process memory. Finder is intentionally excluded here —
    # relaunchDesktopServices (DAG-ordered after writeBoundary) restarts it
    # via launchctl kickstart to preserve window state.
    ${daemonRefresh.refreshServicesMenu}
  '';
}
