let
  inherit (import ../lib.nix) containsRegex;

  applyText = builtins.readFile ../../src/hosts/Windows/apply.ps1;
  flakeText = builtins.readFile ../../src/flake.nix;
  editorsText = builtins.readFile ../../src/modules/editors.nix;
  homeText = builtins.readFile ../../src/modules/home.nix;
  qtpassText = builtins.readFile ../../src/modules/configs/qtpass/qtpass.nix;
  # Validate that qtpass.json is valid JSON and parse it for semantic assertions
  qtpassJson = builtins.fromJSON (builtins.readFile ../../src/modules/configs/qtpass/qtpass.json);
  loadUserRegistryText = builtins.readFile ../../src/hosts/Windows/modules/Load-UserRegistry.ps1;
  neovimInitLuaText = builtins.readFile ../../src/scripts/editors/neovim-init.lua;
  syncQtPassText = builtins.readFile ../../src/hosts/Windows/modules/user/Sync-QtPassConfig.ps1;
  usersRegistryText = builtins.readFile ../../src/modules/users.json;
  windowsUsers = builtins.fromJSON (builtins.readFile ../../src/hosts/Windows/users.json);
in
# Verify QtPass settings are now sourced from qtpass.json via builtins.fromJSON
assert containsRegex "qtPassDefaultSettings = builtins\\.fromJSON" qtpassText;
assert containsRegex "readFile \\./qtpass\\.json" qtpassText;
assert containsRegex "# Method 3" qtpassText;
# Verify qtpass.json contains expected settings (shared baseline)
assert qtpassJson.addGPGId == true;
assert qtpassJson.alwaysOnTop == true;
assert qtpassJson.autoPull == false;
assert qtpassJson.autoPush == false;
assert qtpassJson.clipBoardType == 2;
assert qtpassJson.hideOnClose == true;
assert qtpassJson.hidePassword == true;
assert qtpassJson.passwordLength == 15;
assert qtpassJson.passTemplate == "login\nurl\ndescription\n";
assert qtpassJson.useAutoclear == true;
assert qtpassJson.useAutoclearPanel == true;
assert qtpassJson.useGit == true;
assert qtpassJson.useOtp == true;
assert qtpassJson.usePwgen == true;
assert qtpassJson.useTemplate == true;
assert qtpassJson.useTrayIcon == true;
# Verify platform override (macOS sets hideOnClose = false) is still in qtpass.nix
assert containsRegex "qtPassPlatformSettings" qtpassText;
assert containsRegex "hideOnClose = false" qtpassText;
# Verify home.nix still imports and wires the module
assert containsRegex "qtpassModule = import ./configs/qtpass/qtpass.nix" homeText;
# Verify integration points
assert containsRegex "Sync-QtPassConfig -Enabled:" applyText;
assert containsRegex "qtPassSettingsPath" applyText;
assert containsRegex "EnableQtPassParity" applyText;
# Verify Windows path uses qtpass.json
assert containsRegex "qtpass\\\\qtpass\\.json" applyText;
# Verify Windows side has method label
assert containsRegex "# Method 3" applyText;
# Verify user override structure for all app configs
assert builtins.hasAttr "qtpass" windowsUsers.users.polyipseity;
assert builtins.hasAttr "settings" windowsUsers.users.polyipseity.qtpass;
assert builtins.hasAttr "linearmouse" windowsUsers.users.polyipseity;
assert builtins.hasAttr "settings" windowsUsers.users.polyipseity.linearmouse;
assert builtins.hasAttr "vscode" windowsUsers.users.polyipseity;
assert builtins.hasAttr "settings" windowsUsers.users.polyipseity.vscode;
assert builtins.hasAttr "neovim" windowsUsers.users.polyipseity;
assert builtins.hasAttr "settings" windowsUsers.users.polyipseity.neovim;
assert containsRegex "ConvertTo-PlainObject -InputObject" loadUserRegistryText;
assert containsRegex "qtpass" loadUserRegistryText;
assert containsRegex "function Sync-QtPassConfig" syncQtPassText;
# Verify flake.nix has all app overrides defined
assert containsRegex "readFile ./modules/users.json" flakeText;
assert containsRegex "\"qtpass\"" usersRegistryText;
assert containsRegex "\"linearmouse\"" usersRegistryText;
assert containsRegex "\"vsCode\"" usersRegistryText;
assert containsRegex "\"neovim\"" usersRegistryText;
# Verify Neovim workaround remains in native init.lua management and override path
assert containsRegex "xdg\\.configFile\\.\"nvim/init\\.lua\"\\.text" editorsText;
assert containsRegex "managedAppSettings \"neovim\" neovimDefaultSettings" editorsText;
assert containsRegex "shiftNumberTerminalPrograms = " editorsText;
assert containsRegex "\"kitty\"" editorsText;
assert containsRegex "\"1\" = \"!\"" editorsText;
assert containsRegex "local shifted_key = " neovimInitLuaText;
assert containsRegex "KITTY_WINDOW_ID" neovimInitLuaText;
{
  success = true;
  message = "QtPass settings and editor config tests passed";
}
