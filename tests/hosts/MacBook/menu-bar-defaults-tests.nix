# Static assertions for the menu bar default-hide policy implementation on MacBook.

let
  lib = import <nixpkgs/lib>;

  defaultsNix = builtins.readFile ../../../src/hosts/MacBook/defaults.nix;
  appsJson = builtins.fromJSON (builtins.readFile ../../../src/modules/apps.json);
  menuBarIconsScriptSh = builtins.readFile ../../../src/hosts/MacBook/scripts/macos-configure-menu-bar-icons.sh;
  menuBarScriptSh = builtins.readFile ../../../src/hosts/MacBook/scripts/macos-configure-menu-bar.sh;
  menuBarCliSh = builtins.readFile ../../../src/scripts/menu-bar.sh;
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

  # Per-app icon state now lives in apps.json menuBarIcon blocks, not defaults.nix.
  raycast = appsJson.Raycast.hosts.MacBook.menuBarIcon;
  betterDisplay = appsJson.BetterDisplay.hosts.MacBook.menuBarIcon;
  altTab = appsJson.AltTab.hosts.MacBook.menuBarIcon;
  rectangle = appsJson.Rectangle.hosts.MacBook.menuBarIcon;
  linearMouse = appsJson.LinearMouse.hosts.MacBook.menuBarIcon;
  battery = appsJson.battery.hosts.MacBook.menuBarIcon;
  lulu = appsJson.LuLu.hosts.MacBook.menuBarIcon;
  # Enabled via the macOS 26 Control Center NSStatusItem gate (class f).
  amphetamine = appsJson.Amphetamine.hosts.MacBook.menuBarIcon;
  stats = appsJson.Stats.hosts.MacBook.menuBarIcon;
  mounty = appsJson.Mounty.hosts.MacBook.menuBarIcon;
  orbstack = appsJson.OrbStack.hosts.MacBook.menuBarIcon;
  # Manual (no programmatic mechanism) — declared but not auto-provisioned.
  middleClick = appsJson.MiddleClick.hosts.MacBook.menuBarIcon;
  # Discord tray — converged via activation-script.
  discord = appsJson.Discord.hosts.MacBook.menuBarIcon;
in

# src/hosts/MacBook/defaults.nix — per-app icon keys removed (now in apps.json)
assert !lib.hasInfix "ShowMenuBarIcon" defaultsNix;
assert !lib.hasInfix "hideMenuIcon" defaultsNix;
assert !lib.hasInfix "menubarIconShown" defaultsNix;
assert !lib.hasInfix "hideMenubarIcon" defaultsNix;
assert !lib.hasInfix "menuBarVisibilityMode" defaultsNix;
assert !lib.hasInfix "menuBarBatteryDisplayMode" defaultsNix;
assert !lib.hasInfix "showInMenuBar" linearmouseBlock;
# System menu-bar items stay in defaults.nix / macos-configure-menu-bar.sh
assert lib.hasInfix "TextInputMenu\".visible = false;" defaultsNix;
assert lib.hasInfix "\"NSStatusItem VisibleCC Item-0\" = 0;" defaultsNix;
assert lib.hasInfix "NSStatusItemSpacing = 0;" defaultsNix;
assert lib.hasInfix "NSStatusItemSelectionPadding = 0;" defaultsNix;
assert !lib.hasInfix "BatteryShowPercentage" defaultsNix;
assert !lib.hasInfix "inclusion is defensive" defaultsNix;

# src/modules/apps.json — menuBarIcon SSOT
assert
  raycast.kind == "defaults-key"
  && raycast.domain == "com.raycast.macos"
  && raycast.key == "ShowMenuBarIcon"
  && raycast.iconVisible == false
  && raycast.iconVisibleValue == true
  && raycast.iconHiddenValue == false;
assert
  betterDisplay.kind == "defaults-key"
  && betterDisplay.domain == "pro.betterdisplay.BetterDisplay"
  && betterDisplay.key == "hideMenuIcon"
  && betterDisplay.iconVisible == false
  && betterDisplay.iconVisibleValue == false
  && betterDisplay.iconHiddenValue == true;
assert
  altTab.kind == "defaults-key"
  && altTab.domain == "com.lwouis.alt-tab-macos"
  && altTab.key == "menubarIconShown"
  && altTab.iconVisible == false
  && altTab.iconVisibleValue == "true"
  && altTab.iconHiddenValue == "false";
assert
  rectangle.kind == "defaults-key"
  && rectangle.domain == "com.knollsoft.Rectangle"
  && rectangle.key == "hideMenubarIcon"
  && rectangle.iconVisible == false
  && rectangle.iconVisibleValue == false
  && rectangle.iconHiddenValue == true;
assert
  linearMouse.kind == "defaults-key"
  && linearMouse.domain == "com.lujjjh.LinearMouse"
  && linearMouse.key == "menuBarVisibilityMode"
  && linearMouse.iconVisible == false
  && linearMouse.iconVisibleValue == "always"
  && linearMouse.iconHiddenValue == "never";
assert
  battery.kind == "defaults-key"
  && battery.domain == "com.fiplab.battery"
  && battery.key == "menuBarBatteryDisplayMode"
  && battery.iconVisible == false
  && battery.iconVisibleValue == "on"
  && battery.iconHiddenValue == "off";
assert
  lulu.kind == "plist"
  && lulu.plistPath == "/Library/Objective-See/LuLu/preferences.plist"
  && lulu.key == "noIconMode"
  && lulu.iconVisible == false
  && lulu.iconVisibleValue == false
  && lulu.iconHiddenValue == true;

# Enabled apps converge via the macOS 26 Control Center NSStatusItem gate.
# The key is NOT inverted: true = allowed/shown, false = hidden.
assert
  amphetamine.kind == "defaults-key"
  && amphetamine.domain == "com.apple.controlcenter"
  && amphetamine.key == "NSStatusItem Visible com.if.Amphetamine"
  && amphetamine.iconVisible == true
  && amphetamine.iconVisibleValue == true
  && amphetamine.iconHiddenValue == false;
assert
  stats.kind == "defaults-key"
  && stats.domain == "com.apple.controlcenter"
  && stats.key == "NSStatusItem Visible eu.exelban.Stats"
  && stats.iconVisible == true
  && stats.iconVisibleValue == true
  && stats.iconHiddenValue == false;
assert
  mounty.kind == "defaults-key"
  && mounty.domain == "com.apple.controlcenter"
  && mounty.key == "NSStatusItem Visible com.mounty.app"
  && mounty.iconVisible == true
  && mounty.iconVisibleValue == true
  && mounty.iconHiddenValue == false;
assert
  orbstack.kind == "defaults-key"
  && orbstack.domain == "com.apple.controlcenter"
  && orbstack.key == "NSStatusItem Visible com.orbstack.orbstack"
  && orbstack.iconVisible == true
  && orbstack.iconVisibleValue == true
  && orbstack.iconHiddenValue == false;

# Manual entries: declared but not auto-provisioned (no programmatic mechanism).
assert
  middleClick.kind == "manual"
  && middleClick.provisioned == false
  && middleClick.iconVisible == false;

# Discord tray: converged via activation-script (cross-platform).
assert
  discord.kind == "activation-script"
  && lib.hasInfix "discord-tray" discord.script
  && discord.iconVisible == false;

# src/hosts/MacBook/scripts/macos-configure-menu-bar-icons.sh — invokes menu-bar.sh apply
assert lib.hasInfix "menu-bar.sh" menuBarIconsScriptSh;
assert lib.hasInfix "apply" menuBarIconsScriptSh;

# src/scripts/menu-bar.sh — SETs native pref, never disables it
assert lib.hasInfix "menu_bar_native_set" menuBarCliSh;
assert lib.hasInfix "iconVisibleValue" menuBarCliSh;
assert lib.hasInfix "iconHiddenValue" menuBarCliSh;

# src/hosts/MacBook/scripts/macos-configure-menu-bar.sh — system items only
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

# src/hosts/MacBook/activation.nix — new icon script wired, lulu-icon removed
assert lib.hasInfix "macos-configure-menu-bar-icons.sh" activationNix;
assert lib.hasInfix "macos-configure-menu-bar.sh" activationNix;
assert !lib.hasInfix "macos-configure-lulu-icon.sh" activationNix;

{
  success = true;
  message = "menu bar default-hide policy tests passed";
}
