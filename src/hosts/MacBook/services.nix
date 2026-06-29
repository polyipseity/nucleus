# MacBook/services.nix — macOS Services (right-click context menu items) for Finder.
#
# macOS Services let apps register operations that appear in other apps' menus,
# including Finder's right-click context menu under Services → [Service Name].
# An app bundle with NSServices in its Info.plist is deployed to ~/Applications/,
# then registered with LaunchServices so the service appears in Finder's Services
# menu. The app is compiled from AppleScript source at activation time.
#
# WHY home.activation instead of home.file:
#   home.file creates a symlink to the Nix store, but macOS LaunchServices does
#   not traverse symlinks when discovering Service provider apps. A
#   home.activation script that compiles and deploys the .app on each generation
#   switch guarantees LaunchServices can find it.
#
# WHY compile at activation time:
#   osacompile produces a signing-gatekeeper-compatible .app bundle
#   deterministically from plain-text AppleScript source. The compiled .scpt
#   format is macOS-version-specific, so compiling at activation time (on the
#   target machine) is safer than shipping pre-compiled bytecode.
{ config, lib, ... }: {
  home.activation.deployNucleusManualService = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        set -e

        manual_rel="${config.nucleus.hostManualFile}"
        repo_root="''${NUCLEUS_REPO_ROOT:?services.nix: run via nucleus-apply or set NUCLEUS_REPO_ROOT}"
        manual_abs="$repo_root/$manual_rel"

        app_dir="$HOME/Applications"
        app_path="$app_dir/NucleusManual.app"
        tmpdir=$(mktemp -d)
        as_src="$tmpdir/NucleusManual.applescript"

        cat > "$as_src" << APPLESCRIPT
    on open theFiles
    	do shell script "open \"$manual_abs\""
    end open
    on run
    	do shell script "open \"$manual_abs\""
    end run
    APPLESCRIPT

        mkdir -p "$app_dir"
        /usr/bin/osacompile -l AppleScript -o "$tmpdir/NucleusManual.app" "$as_src" 2>/dev/null

        plist="$tmpdir/NucleusManual.app/Contents/Info.plist"

        /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.nucleus.OpenNucleusManual" "$plist"
        /usr/libexec/PlistBuddy -c "Set :CFBundleName Nucleus Manual" "$plist"
        /usr/libexec/PlistBuddy -c "Add :NSServices array" "$plist"
        /usr/libexec/PlistBuddy -c "Add :NSServices:0 dict" "$plist"
        /usr/libexec/PlistBuddy -c "Add :NSServices:0:NSMenuItem dict" "$plist"
        /usr/libexec/PlistBuddy -c "Add :NSServices:0:NSMenuItem:default string Open Nucleus Manual" "$plist"
        /usr/libexec/PlistBuddy -c "Add :NSServices:0:NSMessage string open" "$plist"
        /usr/libexec/PlistBuddy -c "Add :NSServices:0:NSSendFileTypes array" "$plist"
        /usr/libexec/PlistBuddy -c "Add :NSServices:0:NSSendFileTypes:0 string public.folder" "$plist"
        /usr/libexec/PlistBuddy -c "Add :NSServices:0:NSSendFileTypes:1 string public.data" "$plist"

        if [ -e "$app_path" ] || [ -L "$app_path" ]; then
          rm -rf "$app_path"
        fi
        cp -R "$tmpdir/NucleusManual.app" "$app_dir/"

        LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
        "$LSREGISTER" -R -f "$app_path" 2>/dev/null || true

        rm -rf "$tmpdir"
  '';
}
