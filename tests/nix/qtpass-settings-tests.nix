let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;

  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  applyText = builtins.readFile ../../src/hosts/windows/apply.ps1;
  flakeText = builtins.readFile ../../src/flake.nix;
  editorsText = builtins.readFile ../../src/modules/editors.nix;
  homeText = builtins.readFile ../../src/modules/home.nix;
  loadUserRegistryText = builtins.readFile ../../src/hosts/windows/modules/Load-UserRegistry.ps1;
  syncQtPassText = builtins.readFile ../../src/hosts/windows/modules/Sync-QtPassConfig.ps1;
  usersRegistryText = builtins.readFile ../../src/modules/users.json;
  windowsUsers = builtins.fromJSON (builtins.readFile ../../src/hosts/windows/users.json);
in
# Verify QtPass settings are now stored in home.nix (not separate JSON)
assert containsRegex "qtPassDefaultSettings = " homeText;
assert containsRegex "addGPGId = true" homeText;
assert containsRegex "alwaysOnTop = true" homeText;
assert containsRegex "autoclearPanelSeconds = 5" homeText;
assert containsRegex "autoclearSeconds = 10" homeText;
assert containsRegex "clipBoardType = 2" homeText;
assert containsRegex "hideOnClose = true" homeText;
assert containsRegex "hidePassword = true" homeText;
assert containsRegex "passTemplate = " homeText;
assert containsRegex "passwordCharsselection = 0" homeText;
assert containsRegex "passwordLength = 15" homeText;
assert containsRegex "templateAllFields = true" homeText;
assert containsRegex "useAutoclear = true" homeText;
assert containsRegex "useAutoclearPanel = true" homeText;
assert containsRegex "useGit = true" homeText;
assert containsRegex "useOtp = true" homeText;
assert containsRegex "usePwgen = true" homeText;
assert containsRegex "useTemplate = true" homeText;
assert containsRegex "useTrayIcon = true" homeText;
# Verify platform override (macOS sets hideOnClose = false)
assert containsRegex "hideOnClose = false" homeText;
# Verify integration points
assert containsRegex "Sync-QtPassConfig -Enabled:" applyText;
assert containsRegex "qtPassSettingsPath" applyText;
assert containsRegex "EnableQtPassParity" applyText;
# Verify user override structure for all app configs
assert builtins.hasAttr "qtpass" windowsUsers.users.polyipseity;
assert builtins.hasAttr "settings" windowsUsers.users.polyipseity.qtpass;
assert builtins.hasAttr "linearmouse" windowsUsers.users.polyipseity;
assert builtins.hasAttr "settings" windowsUsers.users.polyipseity.linearmouse;
assert builtins.hasAttr "vsCode" windowsUsers.users.polyipseity;
assert builtins.hasAttr "settings" windowsUsers.users.polyipseity.vsCode;
assert builtins.hasAttr "neovim" windowsUsers.users.polyipseity;
assert builtins.hasAttr "settings" windowsUsers.users.polyipseity.neovim;
assert containsRegex "ConvertTo-PlainObject -InputObject" loadUserRegistryText;
assert containsRegex "qtpass" loadUserRegistryText;
assert containsRegex "function Sync-QtPassConfig" syncQtPassText;
# Verify flake.nix has all app overrides defined
assert containsRegex "qtpass =" flakeText;
assert containsRegex "linearmouse =" flakeText;
assert containsRegex "readFile ./modules/users.json" flakeText;
assert containsRegex "vsCode =" usersRegistryText;
assert containsRegex "neovim =" flakeText;
# Verify Neovim workaround remains in native init.lua management and override path
assert containsRegex "xdg\.configFile\.\"nvim/init\.lua\"\.text" editorsText;
assert containsRegex "managedAppSettings \"neovim\" neovimDefaultSettings" editorsText;
true
