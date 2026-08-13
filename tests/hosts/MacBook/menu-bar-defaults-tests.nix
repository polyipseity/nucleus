# Static assertions for the menu bar default-hide policy implementation on MacBook.

let
  lib = import <nixpkgs/lib>;

  defaultsNix = builtins.readFile ../../../src/hosts/MacBook/defaults.nix;
  luluIconScriptSh = builtins.readFile ../../../src/hosts/MacBook/scripts/macos-configure-lulu-icon.sh;
  menuBarScriptSh = builtins.readFile ../../../src/hosts/MacBook/scripts/macos-configure-menu-bar.sh;
  preferenceGcNix = builtins.readFile ../../../src/platforms/macOS/modules/preference-gc.nix;
  activationNix = builtins.readFile ../../../src/hosts/MacBook/activation.nix;
  # Window from the LinearMouse domain key to the next domain (Amphetamine), so
  # the legacy-key assertion does not see BetterDisplay's unrelated
  # `showInMenuBar = false;` earlier in the file.
  linearmouseBlock = lib.head (
    lib.splitString "com.if.Amphetamine" (
      lib.elemAt (lib.splitString "org.linearmouse.LinearMouse" defaultsNix) 1
    )
  );
in

# src/hosts/MacBook/defaults.nix
assert lib.hasInfix "hideMenubarIcon = true;" defaultsNix;
assert lib.hasInfix "menuBarVisibilityMode = \"never\";" defaultsNix;
assert lib.hasInfix "menuBarBatteryDisplayMode = \"off\";" defaultsNix;
assert !lib.hasInfix "showInMenuBar" linearmouseBlock;
assert lib.hasInfix "TextInputMenu\".visible = false;" defaultsNix;
assert lib.hasInfix "\"NSStatusItem VisibleCC Item-0\" = 0;" defaultsNix;
assert lib.hasInfix "NSStatusItemSpacing = 0;" defaultsNix;
assert lib.hasInfix "NSStatusItemSelectionPadding = 0;" defaultsNix;
assert !lib.hasInfix "BatteryShowPercentage" defaultsNix;
assert !lib.hasInfix "inclusion is defensive" defaultsNix;

# src/hosts/MacBook/scripts/macos-configure-lulu-icon.sh
assert lib.hasInfix "noIconMode" luluIconScriptSh;
assert lib.hasInfix "/Library/Objective-See/LuLu/preferences.plist" luluIconScriptSh;

# src/hosts/MacBook/scripts/macos-configure-menu-bar.sh
assert lib.hasInfix "-currentHost" menuBarScriptSh;
assert lib.hasInfix "MenuItemHidden -bool true" menuBarScriptSh;
assert lib.hasInfix "Battery -int 12" menuBarScriptSh;
assert lib.hasInfix "\"NSStatusItem Visible Battery\" -bool false" menuBarScriptSh;
assert lib.hasInfix "NSStatusItemSpacing" menuBarScriptSh;
assert lib.hasInfix "killall ControlCenter" menuBarScriptSh;
assert lib.hasInfix "launchctl asuser" menuBarScriptSh;

# src/platforms/macOS/modules/preference-gc.nix
assert lib.hasInfix "com.knollsoft.Rectangle" preferenceGcNix;
assert lib.hasInfix "org.linearmouse.LinearMouse" preferenceGcNix;
assert lib.hasInfix "com.lwouis.alt-tab-macos" preferenceGcNix;
assert lib.hasInfix "com.if.Amphetamine" preferenceGcNix;

# src/hosts/MacBook/activation.nix
assert lib.hasInfix "macos-configure-lulu-icon.sh" activationNix;
assert lib.hasInfix "macos-configure-menu-bar.sh" activationNix;

{
  success = true;
  message = "menu bar default-hide policy tests passed";
}
