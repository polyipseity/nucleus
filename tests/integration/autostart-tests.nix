# tests/integration/autostart-tests.nix — Schema and invariant tests for app auto-start management.

let
  inherit (import ../lib.nix) containsRegex;

  appsJsonText = builtins.readFile ../../src/modules/apps.json;
  autostartShText = builtins.readFile ../../src/scripts/autostart.sh;
  autostartPs1Text = builtins.readFile ../../src/scripts/autostart.ps1;
  macosAppAutostartScriptText = builtins.readFile ../../src/hosts/MacBook/scripts/macos-configure-app-autostart.sh;
  nixosAppAutostartScriptText = builtins.readFile ../../src/hosts/NixOS/scripts/nixos-configure-app-autostart.sh;
  syncAppAutostartPs1Text = builtins.readFile ../../src/platforms/Windows/modules/user/Sync-AppAutostart.ps1;
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
assert containsRegex ''"Parsec"'' appsJsonText;
assert containsRegex ''"Steam"'' appsJsonText;
assert containsRegex ''"Telegram"'' appsJsonText;
assert containsRegex ''"WhatsApp"'' appsJsonText;
assert containsRegex ''"MiddleClick"'' appsJsonText;
assert containsRegex ''"Mounty"'' appsJsonText;
assert containsRegex "displayName" appsJsonText;
assert containsRegex "disableNative" appsJsonText;
assert containsRegex "kind" appsJsonText;

# --- autostart.sh structural assertions ---
assert containsRegex "read_registry" autostartShText;
assert containsRegex "app_actual_state" autostartShText;
assert containsRegex "app_converge" autostartShText;
assert containsRegex "do_list" autostartShText;
assert containsRegex "do_status" autostartShText;
assert containsRegex "do_enable" autostartShText;
assert containsRegex "do_disable" autostartShText;
assert containsRegex "do_apply" autostartShText;
assert containsRegex "do_verify" autostartShText;
assert containsRegex ''apps\.json'' autostartShText;
assert containsRegex "osascript" autostartShText;
assert containsRegex "System Events" autostartShText;
assert containsRegex "xdg_autostart_dir" autostartShText;
assert containsRegex "xdg_desktop_write" autostartShText;
assert containsRegex "xdg_desktop_remove" autostartShText;

# --- autostart.ps1 structural assertions ---
assert containsRegex "Resolve-AppNameList" autostartPs1Text;
assert containsRegex "Get-AppActualState" autostartPs1Text;
assert containsRegex "Invoke-AppConverge" autostartPs1Text;
assert containsRegex "Enable-RunKeyEntry" autostartPs1Text;
assert containsRegex "Disable-RunKeyEntry" autostartPs1Text;
assert containsRegex "Unregister-NativeRunKey" autostartPs1Text;
assert containsRegex "Unregister-NativeStartupShortcut" autostartPs1Text;
assert containsRegex ''apps\.json'' autostartPs1Text;
assert containsRegex "Run key" autostartPs1Text;
assert containsRegex "Startup" autostartPs1Text;

# --- macOS activation wiring assertions ---
assert containsRegex "AUTOSTART_CLI.*apply" macosAppAutostartScriptText;

# --- NixOS activation wiring assertions ---
assert containsRegex "AUTOSTART_CLI.*apply" nixosAppAutostartScriptText;

# --- Windows activation wiring assertions ---
assert containsRegex "Sync-AppAutostart" syncAppAutostartPs1Text;
assert containsRegex "autostartScript.*apply" syncAppAutostartPs1Text;

# --- flake.nix nucleusApps wiring assertions ---
# autostart is invoked via activation scripts, not registered as a nucleusApp.
assert containsRegex "nucleus-apply" flakeText;

# --- apps.json scope assertions ---
# Parsec/Telegram/WhatsApp are enabled Run-key entries on Windows.
assert containsRegex ''"Parsec".*"Windows".*"run-key"'' appsJsonText;
assert containsRegex ''"Telegram".*"Windows".*"run-key"'' appsJsonText;
assert containsRegex ''"WhatsApp".*"Windows".*"run-key"'' appsJsonText;

# Steam is disabled on all platforms (declared but not launched).
assert containsRegex ''"Steam".*"enabled".*false'' appsJsonText;

# User-scoped entries must have justification.
assert containsRegex ''"MiddleClick".*justification'' appsJsonText;
assert containsRegex ''"Mounty".*justification'' appsJsonText;

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

# --- Phase C: Structural/parse assertions ---
# read_registry jq filter syntax
assert containsRegex "to_entries.*map" autostartShText;
assert containsRegex "select.*type == .object." autostartShText;

# --- Omission rationale (negative): no equivalent-citing phrases ---
# An omitted host entry must justify omission by platform inapplicability,
# never by citing an equivalent app or native service.
assert all (
  name:
  let
    entry = parsedApps.${name};
    hosts = builtins.attrNames entry.hosts;
    forbidden = [
      "equivalent"
      "provides the"
      "covers"
      "uses the native"
      "native service"
      "WSL"
      "Docker Desktop"
      "PowerToys"
      "WinFsp"
    ];
    justificationForbidden =
      just: all (phrase: !(builtins.match ".*${phrase}.*" just != null)) forbidden;
  in
  all (
    h:
    let
      hostEntry = entry.hosts.${h};
    in
    if hostEntry ? type && hostEntry.type == "omitted" then
      justificationForbidden hostEntry.justification
    else
      true
  ) hosts
) appNames;

# --- Native-disable invariant: non-system-extension runtime entries must disable native ---
assert all (
  name:
  let
    entry = parsedApps.${name};
    hosts = builtins.attrNames entry.hosts;
  in
  all (
    h:
    let
      hostEntry = entry.hosts.${h};
    in
    if
      (hostEntry ? type && hostEntry.type == "omitted")
      || hostEntry ? kind && hostEntry.kind == "system-extension"
    then
      true
    else
      hostEntry.disableNative == true
  ) hosts
) appNames;

true
