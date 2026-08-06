let
  inherit (import ../lib.nix) containsRegex;

  homeText = builtins.readFile ../../src/modules/home.nix;
  syncObsidianText = builtins.readFile ../../src/hosts/Windows/modules/user/Sync-ObsidianConfig.ps1;
  obsidianConfig = builtins.fromJSON (
    builtins.readFile ../../src/users/default/obsidian/obsidian.json
  );
  windowsApplyText = builtins.readFile ../../src/hosts/Windows/apply.ps1;
  usersOverlayText = builtins.readFile ../../src/modules/lib/users-overlay.nix;
in
assert containsRegex "merge-obsidian-json" homeText;
assert containsRegex "selectUserAppConfigFile \"obsidian\" \"obsidian.json\"" homeText;
assert containsRegex "WHY: nativeMenus is not configured" homeText;
assert containsRegex "WHY: checkSlowStartup is not configured" homeText;
assert obsidianConfig.cli == true;
assert obsidianConfig.updateDisabled == true;
assert containsRegex "EnableObsidianParity" windowsApplyText;
assert containsRegex "Sync-ObsidianConfig -Enabled:" windowsApplyText;
assert containsRegex "Resolve-UserConfigFile" syncObsidianText;
assert containsRegex "function Sync-ObsidianConfig" syncObsidianText;
assert containsRegex "selectUserConfigFile" usersOverlayText;
{
  success = true;
  message = "Obsidian configuration parity tests passed";
}
