let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;

  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  flakeText = builtins.readFile ../../src/flake.nix;
  homeText = builtins.readFile ../../src/modules/home.nix;
  linuxText = builtins.readFile ../../src/modules/linux.nix;
  macosText = builtins.readFile ../../src/modules/macos.nix;
  loadUserRegistryText = builtins.readFile ../../src/hosts/windows/modules/Load-UserRegistry.ps1;
  syncObsidianText = builtins.readFile ../../src/hosts/windows/modules/Sync-ObsidianConfig.ps1;
  windowsApplyText = builtins.readFile ../../src/hosts/windows/apply.ps1;
  windowsUsers = builtins.fromJSON (builtins.readFile ../../src/hosts/windows/users.json);
in
assert builtins.hasAttr "obsidian" windowsUsers.users.polyipseity;
assert builtins.hasAttr "settings" windowsUsers.users.polyipseity.obsidian;
assert containsRegex "obsidian =" flakeText;
assert containsRegex "configureObsidianSettings" homeText;
assert containsRegex "obsidianDefaultSettings =" homeText;
assert containsRegex "checkSlowStartup = true" homeText;
assert containsRegex "updateDisabled = true" homeText;
assert containsRegex "EnableObsidianParity" windowsApplyText;
assert containsRegex "Sync-ObsidianConfig -Enabled:" windowsApplyText;
assert containsRegex "obsidian" loadUserRegistryText;
assert containsRegex "function Sync-ObsidianConfig" syncObsidianText;
assert containsRegex "checkSlowStartup = " syncObsidianText;
assert containsRegex "cli = " syncObsidianText;
assert containsRegex "updateDisabled = " syncObsidianText;
assert containsRegex "configureObsidianSettings" linuxText;
assert containsRegex "configureObsidianSettings" macosText;
true
