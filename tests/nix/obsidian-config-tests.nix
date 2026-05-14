let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;

  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  homeText = builtins.readFile ../../src/modules/home.nix;
  linuxText = builtins.readFile ../../src/modules/linux.nix;
  macosText = builtins.readFile ../../src/modules/macos.nix;
  loadUserRegistryText = builtins.readFile ../../src/hosts/windows/modules/Load-UserRegistry.ps1;
  syncObsidianText = builtins.readFile ../../src/hosts/windows/modules/user/Sync-ObsidianConfig.ps1;
  obsidianConfig = builtins.fromJSON (builtins.readFile ../../src/modules/configs/obsidian.json);
  usersRegistryText = builtins.readFile ../../src/modules/users.json;
  windowsApplyText = builtins.readFile ../../src/hosts/windows/apply.ps1;
  windowsUsers = builtins.fromJSON (builtins.readFile ../../src/hosts/windows/users.json);
in
assert builtins.hasAttr "obsidian" windowsUsers.users.polyipseity;
assert builtins.hasAttr "settings" windowsUsers.users.polyipseity.obsidian;
assert containsRegex "\"obsidian\"" usersRegistryText;
assert containsRegex "configureObsidianSettings" homeText;
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
assert containsRegex "configureObsidianSettings" linuxText;
assert containsRegex "configureObsidianSettings" macosText;
true
