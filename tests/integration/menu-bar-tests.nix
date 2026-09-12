# tests/integration/menu-bar-tests.nix — Structural invariant tests for the
# menu-bar / tray-icon registry (mirrors autostart-tests.nix).
#
# Validates apps.json data integrity: schema reference, host validity, menuBarIcon
# structure, and scope invariants. Implementation-coupled grep assertions against
# script source text have been removed — those are now covered by check steps and
# script-level tests.

let
  inherit (import ../lib.nix) assert' containsRegex;

  appsJsonText = builtins.readFile ../../src/modules/apps.json;

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

  knownHosts = [
    "MacBook"
    "NixOS"
    "Windows"
  ];

  # Apps expected to declare menuBarIcon on MacBook
  menuBarApps = [
    "Amphetamine"
    "Stats"
    "Mounty"
    "OrbStack"
    "MiddleClick"
    "Parsec"
    "Telegram"
    "WhatsApp"
    "Steam"
    "Discord"
    "Discord Canary"
    "BetterDisplay"
    "Rectangle"
    "LuLu"
    "Raycast"
    "AltTab"
    "LinearMouse"
    "battery"
  ];

  # Apps expected to have manual kind (not auto-provisioned)
  manualApps = [
    "MiddleClick"
    "Parsec"
  ];

  # Apps expected to use activation-script for Discord tray
  discordApps = [
    "Discord"
    "Discord Canary"
  ];
in
{
  tests = builtins.filter (x: x != null) [
    # --- Schema reference integrity ---
    (assert' (containsRegex ''apps\.schema\.json'' appsJsonText)
      "apps.json must reference apps.schema.json")

    # --- Required field presence in apps.json ---
    (assert' (containsRegex "menuBarIcon" appsJsonText)
      "apps.json must define menuBarIcon entries")
    (assert' (containsRegex "iconVisible" appsJsonText)
      "apps.json must define iconVisible fields")

    # --- Each app has at least one non-omitted host ---
    (assert' (
      all (
        name:
        let
          entry = parsedApps.${name};
          hosts = builtins.attrNames entry.hosts;
        in
        any (h: !(entry.hosts.${h} ? type) || entry.hosts.${h}.type != "omitted") hosts
      ) appNames
    ) "Every app must have at least one non-omitted host")

    # --- All host keys are valid ---
    (assert' (
      all (
        name:
        let
          entry = parsedApps.${name};
        in
        all (h: any (kh: kh == h) knownHosts) (builtins.attrNames entry.hosts)
      ) appNames
    ) "All host keys must be MacBook, NixOS, or Windows")

    # --- Apps with controllable tray icons must declare menuBarIcon ---
    (assert' (
      all (name: parsedApps.${name}.hosts.MacBook ? menuBarIcon) menuBarApps
    ) "Every app with a controllable tray icon must declare menuBarIcon on MacBook")

    # --- Manual entries must be declared but not auto-provisioned ---
    (assert' (
      all (
        name:
        let macbookHost = parsedApps.${name}.hosts.MacBook;
        in macbookHost.kind == "manual" && macbookHost.provisioned == false
      ) manualApps
    ) "Manual apps must have kind=manual and provisioned=false")

    # --- Discord apps use activation-script for tray convergence ---
    (assert' (
      all (
        name:
        let macbookHost = parsedApps.${name}.hosts.MacBook;
        in macbookHost ? activation-script
      ) discordApps
    ) "Discord apps must use activation-script for tray convergence")
  ];
  success = true;
  message = "Menu bar structural tests passed";
}
