# tests/integration/menu-bar-tests.nix — Schema and invariant tests for the
# menu-bar / tray-icon registry convergence (mirrors autostart-tests.nix).

let
  inherit (import ../lib.nix) containsRegex;

  appsJsonText = builtins.readFile ../../src/modules/apps.json;
  menuBarShText = builtins.readFile ../../src/scripts/menu-bar.sh;
  menuBarPs1Text = builtins.readFile ../../src/scripts/menu-bar.ps1;
  macosMenuBarScriptText = builtins.readFile ../../src/hosts/MacBook/scripts/macos-configure-menu-bar-icons.sh;
  nixosMenuBarScriptText = builtins.readFile ../../src/hosts/NixOS/scripts/nixos-configure-menu-bar.sh;
  syncMenuBarPs1Text = builtins.readFile ../../src/platforms/Windows/modules/user/Sync-MenuBar.ps1;
  flakeText = builtins.readFile ../../src/flake.nix;

  # Parsed apps.json for structural assertions
  parsedApps = builtins.fromJSON appsJsonText;
  appNames = builtins.filter (n: parsedApps.${n} ? hosts) (builtins.attrNames parsedApps);

  # Tail-recursive list helpers
  all =
    pred: list:
    if list == [ ] then
      true
    else if pred (builtins.head list) then
      all pred (builtins.tail list)
    else
      false;
  any =
    pred: list:
    if list == [ ] then
      false
    else if pred (builtins.head list) then
      true
    else
      any pred (builtins.tail list);
in

# --- apps.json structural assertions ---
assert containsRegex ''\$schema.*apps\.schema\.json'' appsJsonText;
assert containsRegex "menuBarIcon" appsJsonText;
assert containsRegex "iconVisible" appsJsonText;
assert containsRegex "iconVisibleValue" appsJsonText;
assert containsRegex "iconHiddenValue" appsJsonText;
assert containsRegex "defaults-key" appsJsonText;
assert containsRegex "plist" appsJsonText;
assert containsRegex "activation-script" appsJsonText;
assert containsRegex "manual" appsJsonText;
assert containsRegex "provisioned" appsJsonText;

# --- menu-bar.sh structural assertions ---
assert containsRegex "read_registry" menuBarShText;
assert containsRegex "menu_bar_value_for" menuBarShText;
assert containsRegex "menu_bar_native_set" menuBarShText;
assert containsRegex "menu_bar_actual_visible" menuBarShText;
assert containsRegex "menu_bar_converge" menuBarShText;
assert containsRegex "do_list" menuBarShText;
assert containsRegex "do_status" menuBarShText;
assert containsRegex "do_show" menuBarShText;
assert containsRegex "do_hide" menuBarShText;
assert containsRegex "do_apply" menuBarShText;
assert containsRegex "do_verify" menuBarShText;
assert containsRegex ''apps\.json'' menuBarShText;
assert containsRegex "defaults write" menuBarShText;
assert containsRegex "pgrep" menuBarShText;
assert containsRegex "pkill" menuBarShText;
assert containsRegex "nixos_dispatch_per_user" menuBarShText;

# --- menu-bar.ps1 structural assertions ---
assert containsRegex "Get-MenuBarNativeValue" menuBarPs1Text;
assert containsRegex "Set-MenuBarNative" menuBarPs1Text;
assert containsRegex "Get-MenuBarActualVisible" menuBarPs1Text;
# Windows verify must skip manual entries (no drift flag), mirroring POSIX do_verify.
assert containsRegex "no drift check" menuBarPs1Text;
assert containsRegex "Invoke-MenuBarConverge" menuBarPs1Text;
assert containsRegex "Resolve-AppNameList" menuBarPs1Text;
assert containsRegex "Format-ListTable" menuBarPs1Text;
assert containsRegex ''apps\.json'' menuBarPs1Text;

# --- macOS activation wiring assertions ---
assert containsRegex "MENU_BAR_CLI.*apply" macosMenuBarScriptText;

# --- NixOS activation wiring assertions ---
assert containsRegex "MENU_BAR_CLI.*apply" nixosMenuBarScriptText;

# --- Windows activation wiring assertions ---
assert containsRegex "Sync-MenuBar" syncMenuBarPs1Text;
assert containsRegex "menuBarScript.*apply" syncMenuBarPs1Text;

# --- flake.nix nucleusApps wiring assertions ---
# menu-bar is invoked via activation scripts, not registered as a nucleusApp.
assert containsRegex "nucleus-apply" flakeText;

# --- apps.json scope assertions ---
# Every MacBook host entry that is not omitted must declare a menuBarIcon block
# for the apps that ship a controllable tray icon (Raycast, BetterDisplay,
# AltTab, Rectangle, LinearMouse, battery, LuLu).
assert containsRegex ''"Raycast".*"menuBarIcon"'' appsJsonText;
assert containsRegex ''"BetterDisplay".*"menuBarIcon"'' appsJsonText;
assert containsRegex ''"AltTab".*"menuBarIcon"'' appsJsonText;
assert containsRegex ''"Rectangle".*"menuBarIcon"'' appsJsonText;
assert containsRegex ''"LinearMouse".*"menuBarIcon"'' appsJsonText;
assert containsRegex ''"battery".*"menuBarIcon"'' appsJsonText;
assert containsRegex ''"LuLu".*"menuBarIcon"'' appsJsonText;

# --- Structural: each app has at least one non-omitted host ---
assert all (
  name:
  let
    entry = parsedApps.${name};
    hosts = builtins.attrNames entry.hosts;
  in
  any (h: !(entry.hosts.${h} ? type) || entry.hosts.${h}.type != "omitted") hosts
) appNames;

# --- Structural: all host keys are valid (MacBook, NixOS, Windows) ---
assert all (
  name:
  let
    entry = parsedApps.${name};
    knownHosts = [
      "MacBook"
      "NixOS"
      "Windows"
    ];
  in
  all (h: any (kh: kh == h) knownHosts) (builtins.attrNames entry.hosts)
) appNames;

# --- Schema reference integrity ---
assert containsRegex ''apps\.schema\.json'' appsJsonText;

# --- Inverted-key invariant: inverted apps express inversion via values ---
# BetterDisplay / Rectangle / LuLu use inverted native keys; the registry must
# encode the inversion in iconVisibleValue / iconHiddenValue, never a disable flag.
# (Exact value pairs are asserted in tests/hosts/MacBook/menu-bar-defaults-tests.nix.)
assert containsRegex ''"BetterDisplay".*"menuBarIcon"'' appsJsonText;
assert containsRegex ''"Rectangle".*"menuBarIcon"'' appsJsonText;
assert containsRegex ''"LuLu".*"menuBarIcon"'' appsJsonText;

# --- Scope: every app with a controllable tray icon declares menuBarIcon on
# every non-omitted host it runs on (enable via Control Center gate, disable
# via manual/activation-script, or keep the existing defaults-key/plist block).
assert containsRegex ''"Amphetamine".*"menuBarIcon"'' appsJsonText;
assert containsRegex ''"Stats".*"menuBarIcon"'' appsJsonText;
assert containsRegex ''"Mounty".*"menuBarIcon"'' appsJsonText;
assert containsRegex ''"OrbStack".*"menuBarIcon"'' appsJsonText;
assert containsRegex ''"MiddleClick".*"menuBarIcon"'' appsJsonText;
assert containsRegex ''"Parsec".*"menuBarIcon"'' appsJsonText;
assert containsRegex ''"Telegram".*"menuBarIcon"'' appsJsonText;
assert containsRegex ''"WhatsApp".*"menuBarIcon"'' appsJsonText;
assert containsRegex ''"Steam".*"menuBarIcon"'' appsJsonText;
assert containsRegex ''"Discord".*"menuBarIcon"'' appsJsonText;
assert containsRegex ''"Discord Canary".*"menuBarIcon"'' appsJsonText;

# --- Control Center NSStatusItem gate: enabled apps converge via the
# com.apple.controlcenter "NSStatusItem Visible <BundleID>" boolean (true =
# allowed/shown, false = hidden; NOT inverted).
assert containsRegex ''"com.apple.controlcenter"'' appsJsonText;
assert containsRegex ''"NSStatusItem Visible com.if.Amphetamine"'' appsJsonText;
assert containsRegex ''"NSStatusItem Visible eu.exelban.Stats"'' appsJsonText;
assert containsRegex ''"NSStatusItem Visible com.mounty.app"'' appsJsonText;
assert containsRegex ''"NSStatusItem Visible com.orbstack.orbstack"'' appsJsonText;

# --- Manual entries: declared but not auto-provisioned (no programmatic
# mechanism).  Engine must skip SET and surface via list/verify.
assert containsRegex ''"MiddleClick".*"kind": "manual".*"provisioned": false'' appsJsonText;
assert containsRegex ''"Parsec".*"kind": "manual".*"provisioned": false'' appsJsonText;

# --- Discord tray: converged via activation-script (cross-platform).
assert containsRegex ''"Discord".*"activation-script".*discord-tray'' appsJsonText;
assert containsRegex ''"Discord Canary".*"activation-script".*discord-tray'' appsJsonText;

true
