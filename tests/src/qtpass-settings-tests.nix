let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;

  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  applyText = builtins.readFile ../../src/hosts/Windows/apply.ps1;
  flakeText = builtins.readFile ../../src/flake.nix;
  editorsText = builtins.readFile ../../src/modules/editors.nix;
  homeText = builtins.readFile ../../src/modules/home.nix;
  qtpassText = builtins.readFile ../../src/modules/configs/qtpass.nix;
  loadUserRegistryText = builtins.readFile ../../src/hosts/Windows/modules/Load-UserRegistry.ps1;
  syncQtPassText = builtins.readFile ../../src/hosts/Windows/modules/user/Sync-QtPassConfig.ps1;
  usersRegistryText = builtins.readFile ../../src/modules/users.json;
  windowsUsers = builtins.fromJSON (builtins.readFile ../../src/hosts/Windows/users.json);
in
# Verify QtPass settings are now stored in configs/qtpass.nix (not home.nix)
assert containsRegex "qtPassDefaultSettings = " qtpassText;
assert containsRegex "addGPGId = true" qtpassText;
assert containsRegex "alwaysOnTop = true" qtpassText;
assert containsRegex "autoclearPanelSeconds = 5" qtpassText;
assert containsRegex "autoclearSeconds = 10" qtpassText;
assert containsRegex "clipBoardType = 2" qtpassText;
assert containsRegex "hideOnClose = true" qtpassText;
assert containsRegex "hidePassword = true" qtpassText;
assert containsRegex "passTemplate = " qtpassText;
assert containsRegex "passwordCharsselection = 0" qtpassText;
assert containsRegex "passwordLength = 15" qtpassText;
assert containsRegex "templateAllFields = true" qtpassText;
assert containsRegex "useAutoclear = true" qtpassText;
assert containsRegex "useAutoclearPanel = true" qtpassText;
assert containsRegex "useGit = true" qtpassText;
assert containsRegex "useOtp = true" qtpassText;
assert containsRegex "usePwgen = true" qtpassText;
assert containsRegex "useTemplate = true" qtpassText;
assert containsRegex "useTrayIcon = true" qtpassText;
# Verify platform override (macOS sets hideOnClose = false)
assert containsRegex "hideOnClose = false" qtpassText;
# Verify home.nix still imports and wires the module
assert containsRegex "qtpassModule = import ./configs/qtpass.nix" homeText;
# Verify integration points
assert containsRegex "Sync-QtPassConfig -Enabled:" applyText;
assert containsRegex "qtPassSettingsPath" applyText;
assert containsRegex "EnableQtPassParity" applyText;
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
assert containsRegex "xdg\.configFile\.\"nvim/init\.lua\"\.text" editorsText;
assert containsRegex "managedAppSettings \"neovim\" neovimDefaultSettings" editorsText;
assert containsRegex "shiftNumberTerminalPrograms = " editorsText;
assert containsRegex "\"kitty\"" editorsText;
assert containsRegex "\"1\" = \"!\"" editorsText;
assert containsRegex "local shifted_key = " editorsText;
assert containsRegex "KITTY_WINDOW_ID" editorsText;
true
