# tests/integration/apps-json-tests.nix — Schema and invariant tests for app auto-start and menu-bar.
#
# Validates apps.json data integrity: schema reference, host validity, autostart
# wiring, menuBarIcon structure, and scope invariants.
#
# Run with: nix-instantiate --eval tests/integration/apps-json-tests.nix

let
  inherit (import ../lib.nix) assert' containsRegex all any;

  appsJsonText = builtins.readFile ../../src/modules/apps.json;
  autostartShText = builtins.readFile ../../src/scripts/autostart.sh;
  autostartPs1Text = builtins.readFile ../../src/scripts/autostart.ps1;
  macosAppAutostartScriptText = builtins.readFile ../../src/hosts/MacBook/scripts/macos-configure-app-autostart.sh;
  nixosAppAutostartScriptText = builtins.readFile ../../src/hosts/NixOS/scripts/nixos-configure-app-autostart.sh;
  syncAppAutostartPs1Text = builtins.readFile ../../src/platforms/Windows/modules/user/Sync-AppAutostart.ps1;
  flakeText = builtins.readFile ../../src/flake.nix;

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
    # === apps.json structural assertions ===
    (assert' (containsRegex ''\$schema.*apps\.schema\.json'' appsJsonText) "apps.json must reference apps.schema.json")
    (assert' (containsRegex ''"Parsec"'' appsJsonText) "apps.json has Parsec")
    (assert' (containsRegex ''"Steam"'' appsJsonText) "apps.json has Steam")
    (assert' (containsRegex ''"Telegram"'' appsJsonText) "apps.json has Telegram")
    (assert' (containsRegex ''"WhatsApp"'' appsJsonText) "apps.json has WhatsApp")
    (assert' (containsRegex ''"MiddleClick"'' appsJsonText) "apps.json has MiddleClick")
    (assert' (containsRegex ''"Mounty"'' appsJsonText) "apps.json has Mounty")
    (assert' (containsRegex "displayName" appsJsonText) "apps.json has displayName")
    (assert' (containsRegex "autostartDisableNative" appsJsonText) "apps.json has autostartDisableNative")
    (assert' (containsRegex "kind" appsJsonText) "apps.json has kind")
    (assert' (containsRegex "menuBarIcon" appsJsonText) "apps.json has menuBarIcon entries")
    (assert' (containsRegex "iconVisible" appsJsonText) "apps.json has iconVisible fields")

    # === autostart.sh structural assertions ===
    (assert' (containsRegex "read_registry" autostartShText) "autostart.sh: read_registry")
    (assert' (containsRegex "app_actual_state" autostartShText) "autostart.sh: app_actual_state")
    (assert' (containsRegex "app_converge" autostartShText) "autostart.sh: app_converge")
    (assert' (containsRegex "do_list" autostartShText) "autostart.sh: do_list")
    (assert' (containsRegex "do_status" autostartShText) "autostart.sh: do_status")
    (assert' (containsRegex "do_enable" autostartShText) "autostart.sh: do_enable")
    (assert' (containsRegex "do_disable" autostartShText) "autostart.sh: do_disable")
    (assert' (containsRegex "do_apply" autostartShText) "autostart.sh: do_apply")
    (assert' (containsRegex "do_verify" autostartShText) "autostart.sh: do_verify")
    (assert' (containsRegex ''apps\.json'' autostartShText) "autostart.sh: reads apps.json")
    (assert' (containsRegex "osascript" autostartShText) "autostart.sh: uses osascript")
    (assert' (containsRegex "macos_launchagent_ensure" autostartShText) "autostart.sh: macos_launchagent_ensure")
    (assert' (containsRegex "macos_remove_app_launchagent" autostartShText) "autostart.sh: macos_remove_app_launchagent")
    (assert' (containsRegex "LaunchAgents" autostartShText) "autostart.sh: LaunchAgents")
    (assert' (containsRegex "xdg_autostart_dir" autostartShText) "autostart.sh: xdg_autostart_dir")
    (assert' (containsRegex "xdg_desktop_write" autostartShText) "autostart.sh: xdg_desktop_write")
    (assert' (containsRegex "xdg_desktop_remove" autostartShText) "autostart.sh: xdg_desktop_remove")
    (assert' (containsRegex "to_entries.*map" autostartShText) "autostart.sh: read_registry jq filter")
    (assert' (containsRegex "select.*type == .object." autostartShText) "autostart.sh: jq select filter")

    # === autostart.ps1 structural assertions ===
    (assert' (containsRegex "Resolve-AppNameList" autostartPs1Text) "autostart.ps1: Resolve-AppNameList")
    (assert' (containsRegex "Get-AppActualState" autostartPs1Text) "autostart.ps1: Get-AppActualState")
    (assert' (containsRegex "Invoke-AppConverge" autostartPs1Text) "autostart.ps1: Invoke-AppConverge")
    (assert' (containsRegex "Enable-RunKeyEntry" autostartPs1Text) "autostart.ps1: Enable-RunKeyEntry")
    (assert' (containsRegex "Disable-RunKeyEntry" autostartPs1Text) "autostart.ps1: Disable-RunKeyEntry")
    (assert' (containsRegex "Unregister-NativeRunKey" autostartPs1Text) "autostart.ps1: Unregister-NativeRunKey")
    (assert' (containsRegex "Unregister-NativeStartupShortcut" autostartPs1Text) "autostart.ps1: Unregister-NativeStartupShortcut")
    (assert' (containsRegex ''apps\.json'' autostartPs1Text) "autostart.ps1: reads apps.json")
    (assert' (containsRegex "Run key" autostartPs1Text) "autostart.ps1: Run key")
    (assert' (containsRegex "Startup" autostartPs1Text) "autostart.ps1: Startup")

    # === Platform activation wiring ===
    (assert' (containsRegex "AUTOSTART_CLI.*apply" macosAppAutostartScriptText) "macOS: AUTOSTART_CLI apply")
    (assert' (containsRegex "AUTOSTART_CLI.*apply" nixosAppAutostartScriptText) "NixOS: AUTOSTART_CLI apply")
    (assert' (containsRegex "Sync-AppAutostart" syncAppAutostartPs1Text) "Windows: Sync-AppAutostart")
    (assert' (containsRegex "autostartScript.*apply" syncAppAutostartPs1Text) "Windows: autostartScript apply")

    # === flake.nix wiring ===
    (assert' (containsRegex "nucleus-apply" flakeText) "nucleus-apply in flake.nix")

    # === apps.json scope assertions ===
    (assert' (containsRegex ''"Steam".*"autostartEnabled".*false'' appsJsonText) "Steam autostartEnabled = false")
    (assert' (containsRegex ''"MiddleClick".*justification'' appsJsonText) "MiddleClick has justification")
    (assert' (containsRegex ''"Mounty".*justification'' appsJsonText) "Mounty has justification")

    # === Structural: each app has at least one non-omitted host ===
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

    # === Structural: all host keys are valid ===
    (assert' (
      all (
        name:
        let
          entry = parsedApps.${name};
        in
        all (h: any (kh: kh == h) knownHosts) (builtins.attrNames entry.hosts)
      ) appNames
    ) "All host keys must be MacBook, NixOS, or Windows")

    # === Schema reference integrity ===
    (assert' (containsRegex ''apps\.schema\.json'' appsJsonText) "apps.json references apps.schema.json")

    # === Omission rationale (negative) ===
    (assert' (
      all (
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
      ) appNames
    ) "Omitted entries must not cite equivalent apps")

    # === Native-disable invariant ===
    (assert' (
      all (
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
      ) appNames
    ) "Non-system-extension runtime entries must disable native")

    # === macOS system-extension entries must declare bundleId + approvalInstructions ===
    (assert' (
      all (
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
      ) appNames
    ) "macOS system-extension entries must have bundleId + approvalInstructions")

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
    (assert' (
      all (name: parsedApps.${name}.hosts.MacBook ? menuBarIcon) menuBarApps
    ) "Every app with a controllable tray icon must declare menuBarIcon on MacBook")

    # === Menu-bar: manual entries ===
    (assert' (
      all (
        name:
        let macbookHost = parsedApps.${name}.hosts.MacBook;
        in macbookHost.menuBarIcon.kind == "manual" && macbookHost.menuBarIcon.provisioned == false
      ) manualApps
    ) "Manual apps must have menuBarIcon.kind=manual and menuBarIcon.provisioned=false")

    # === Menu-bar: Discord apps use activation-script ===
    (assert' (
      all (
        name:
        let macbookHost = parsedApps.${name}.hosts.MacBook;
        in macbookHost.menuBarIcon.kind == "activation-script"
      ) discordApps
    ) "Discord apps must use activation-script for tray convergence")
  ];

  success = true;
  message = "Apps.json structural tests passed";
}
