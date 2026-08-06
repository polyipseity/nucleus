let
  inherit (import ../lib.nix) containsRegex;

  applyText = builtins.readFile ../../src/hosts/Windows/apply.ps1;
  homeText = builtins.readFile ../../src/modules/home.nix;
  qtpassText = builtins.readFile ../../src/modules/configs/qtpass/qtpass.nix;
  qtpassJson = builtins.fromJSON (builtins.readFile ../../src/users/default/qtpass/qtpass.json);
  syncQtPassText = builtins.readFile ../../src/hosts/Windows/modules/user/Sync-QtPassConfig.ps1;
  usersOverlayText = builtins.readFile ../../src/modules/lib/users-overlay.nix;
in
assert containsRegex "qtPassDefaultSettings" homeText;
assert containsRegex "selectUserAppConfigFile \"qtpass\" \"qtpass.json\"" homeText;
assert containsRegex "# check-suppress:config-method: method 3" qtpassText;
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
assert containsRegex "qtPassPlatformSettings" qtpassText;
assert containsRegex "hideOnClose = false" qtpassText;
assert containsRegex "qtpassModule = import ./configs/qtpass/qtpass.nix" homeText;
assert containsRegex "Sync-QtPassConfig -Enabled:" applyText;
assert containsRegex "Resolve-UserConfigFile" syncQtPassText;
assert containsRegex "EnableQtPassParity" applyText;
assert containsRegex "# check-suppress:config-method: method 3" applyText;
assert containsRegex "selectUserConfigFile" usersOverlayText;
assert containsRegex "function Sync-QtPassConfig" syncQtPassText;
{
  success = true;
  message = "QtPass settings and editor config tests passed";
}
