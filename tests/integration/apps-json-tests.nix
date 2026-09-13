# tests/integration/apps-json-tests.nix — Structural invariant tests for app auto-start and menu-bar.
#
# Validates apps.json data integrity: host validity, autostart wiring,
# menuBarIcon structure, and scope invariants.
#
# Run with: nix-instantiate --eval tests/integration/apps-json-tests.nix

let
  inherit (import ../lib.nix)
    assert'
    all
    any
    ;

  appsJsonText = builtins.readFile ../../src/modules/apps.json;

  parsedApps = builtins.fromJSON appsJsonText;
  appNames = builtins.filter (n: parsedApps.${n} ? hosts) (builtins.attrNames parsedApps);

  knownHosts = [
    "MacBook"
    "NixOS"
    "Windows"
  ];

  # Menu-bar apps expected to declare menuBarIcon on MacBook
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

  manualApps = [
    "MiddleClick"
    "Parsec"
  ];

  discordApps = [
    "Discord"
    "Discord Canary"
  ];
in
{
  tests = builtins.filter (x: x != null) [
    # === Structural: each app has at least one non-omitted host ===
    (assert' (all (
      name:
      let
        entry = parsedApps.${name};
        hosts = builtins.attrNames entry.hosts;
      in
      any (h: !(entry.hosts.${h} ? type) || entry.hosts.${h}.type != "omitted") hosts
    ) appNames) "Every app must have at least one non-omitted host")

    # === Structural: all host keys are valid ===
    (assert' (all (
      name:
      let
        entry = parsedApps.${name};
      in
      all (h: any (kh: kh == h) knownHosts) (builtins.attrNames entry.hosts)
    ) appNames) "All host keys must be MacBook, NixOS, or Windows")

    # === Omission rationale (negative) ===
    (assert' (all (
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
    ) appNames) "Omitted entries must not cite equivalent apps")

    # === Native-disable invariant ===
    (assert' (all (
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
          hostEntry.autostartDisableNative == true
      ) hosts
    ) appNames) "Non-system-extension runtime entries must disable native")

    # === macOS system-extension entries must declare bundleId + approvalInstructions ===
    (assert' (all (
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
        if hostEntry ? kind && hostEntry.kind == "system-extension" && hostEntry.platform == "macOS" then
          hostEntry ? bundleId
          && hostEntry.bundleId != ""
          && hostEntry ? approvalInstructions
          && hostEntry.approvalInstructions != ""
        else
          true
      ) hosts
    ) appNames) "macOS system-extension entries must have bundleId + approvalInstructions")

    # === Per-app approval instructions ===
    (assert' (
      builtins.match ".*File System Extensions.*" (
        parsedApps."fuse-t".hosts.MacBook.approvalInstructions or ""
      ) != null
    ) "fuse-t: File System Extensions approval instructions")
    (assert' (
      builtins.match ".*Accessibility.*" (
        parsedApps."Chrome Remote Desktop Host".hosts.MacBook.approvalInstructions or ""
      ) != null
    ) "Chrome Remote Desktop Host: Accessibility approval instructions")

    # === Menu-bar: apps with controllable tray icons must declare menuBarIcon ===
    (assert' (all (
      name: parsedApps.${name}.hosts.MacBook ? menuBarIcon
    ) menuBarApps) "Every app with a controllable tray icon must declare menuBarIcon on MacBook")

    # === Menu-bar: manual entries ===
    (assert' (all (
      name:
      let
        macbookHost = parsedApps.${name}.hosts.MacBook;
      in
      macbookHost.menuBarIcon.kind == "manual" && macbookHost.menuBarIcon.provisioned == false
    ) manualApps) "Manual apps must have menuBarIcon.kind=manual and menuBarIcon.provisioned=false")

    # === Menu-bar: Discord apps use activation-script ===
    (assert' (all (
      name:
      let
        macbookHost = parsedApps.${name}.hosts.MacBook;
      in
      macbookHost.menuBarIcon.kind == "activation-script"
    ) discordApps) "Discord apps must use activation-script for tray convergence")
  ];

  success = true;
  message = "Apps.json structural tests passed";
}
