let
  inherit (import ../lib.nix) containsRegex;

  homeText = builtins.readFile ../../src/modules/home.nix;
  loadUserRegistryText = builtins.readFile ../../src/hosts/Windows/modules/Load-UserRegistry.ps1;
  syncObsidianText = builtins.readFile ../../src/hosts/Windows/modules/user/Sync-ObsidianConfig.ps1;
  obsidianConfig = builtins.fromJSON (
    builtins.readFile ../../src/modules/configs/obsidian/obsidian.json
  );
  usersRegistryText = builtins.readFile ../../src/modules/users.json;
  windowsApplyText = builtins.readFile ../../src/hosts/Windows/apply.ps1;
  windowsUsers = builtins.fromJSON (builtins.readFile ../../src/hosts/Windows/users.json);
in
assert builtins.hasAttr "obsidian" windowsUsers.users.polyipseity;
assert builtins.hasAttr "settings" windowsUsers.users.polyipseity.obsidian;
assert containsRegex "\"obsidian\"" usersRegistryText;
assert containsRegex "merge-obsidian-json" homeText;
assert containsRegex "obsidianDefaultSettings = builtins.fromJSON" homeText;
assert containsRegex "WHY nativeMenus is not configured" homeText;
assert containsRegex "WHY checkSlowStartup is not configured" homeText;
assert obsidianConfig.cli == true;
assert obsidianConfig.updateDisabled == true;
assert containsRegex "EnableObsidianParity" windowsApplyText;
assert containsRegex "Sync-ObsidianConfig -Enabled:" windowsApplyText;
assert containsRegex "obsidian" loadUserRegistryText;
assert containsRegex "function Sync-ObsidianConfig" syncObsidianText;
assert containsRegex "cli =" syncObsidianText;
assert containsRegex "updateDisabled =" syncObsidianText;
assert containsRegex "WHY nativeMenus is not configured" syncObsidianText;
assert containsRegex "WHY checkSlowStartup is not configured" syncObsidianText;
{
  success = true;
  message = "Obsidian configuration parity tests passed";
}
