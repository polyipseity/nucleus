let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;

  containsRegex = pattern: haystack:
    builtins.match ".*${pattern}.*" (flatten haystack) != null;

  applyText = builtins.readFile ../../src/hosts/windows/apply.ps1;
  flakeText = builtins.readFile ../../src/flake.nix;
  homeText = builtins.readFile ../../src/modules/home.nix;
  loadUserRegistryText = builtins.readFile ../../src/hosts/windows/modules/Load-UserRegistry.ps1;
  syncQtPassText = builtins.readFile ../../src/hosts/windows/modules/Sync-QtPassConfig.ps1;
  windowsUsers = builtins.fromJSON (builtins.readFile ../../src/hosts/windows/users.json);
  qtPassSettings = builtins.fromJSON (builtins.readFile ../../src/modules/configs/qtpass/settings.json);
in
assert qtPassSettings.addGPGId == true;
assert qtPassSettings.alwaysOnTop == true;
assert qtPassSettings.autoclearPanelSeconds == 5;
assert qtPassSettings.autoclearSeconds == 10;
assert qtPassSettings.clipBoardType == 2;
assert qtPassSettings.hideOnClose == true;
assert qtPassSettings.hidePassword == true;
assert qtPassSettings.passTemplate == "login\nurl\ndescription\n";
assert qtPassSettings.passwordCharsselection == 0;
assert qtPassSettings.passwordLength == 15;
assert qtPassSettings.templateAllFields == true;
assert qtPassSettings.useAutoclear == true;
assert qtPassSettings.useAutoclearPanel == true;
assert qtPassSettings.useGit == true;
assert qtPassSettings.useOtp == true;
assert qtPassSettings.usePwgen == true;
assert qtPassSettings.useTemplate == true;
assert qtPassSettings.useTrayIcon == true;
assert containsRegex "hideOnClose = false;" homeText;
assert containsRegex "qtPassDefaultSettings = builtins\.fromJSON" homeText;
assert containsRegex "configs/qtpass/settings\.json" homeText;
assert containsRegex "Sync-QtPassConfig -Enabled:" applyText;
assert containsRegex "qtPassSettingsPath" applyText;
assert containsRegex "EnableQtPassParity" applyText;
assert builtins.attrNames windowsUsers.users.polyipseity.qtpass.settings == [ ];
assert containsRegex "qtpass =" flakeText;
assert containsRegex "ConvertTo-PlainObject -InputObject" loadUserRegistryText;
assert containsRegex "qtpass" loadUserRegistryText;
assert containsRegex "function Sync-QtPassConfig" syncQtPassText;
true
