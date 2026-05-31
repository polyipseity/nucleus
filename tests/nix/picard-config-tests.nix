let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;
  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  homeText = builtins.readFile ../../src/modules/home.nix;
  windowsApplyText = builtins.readFile ../../src/hosts/Windows/apply.ps1;
  windowsLoadUserRegistryText = builtins.readFile ../../src/hosts/Windows/modules/Load-UserRegistry.ps1;
  windowsPicardConfigText = builtins.readFile ../../src/hosts/Windows/modules/user/Sync-PicardConfig.ps1;
  picardDefaultsIniText = builtins.readFile ../../src/modules/configs/picard/Picard.ini;

  usersRegistry = builtins.fromJSON (builtins.readFile ../../src/modules/users.json);
  windowsUsersRegistry = builtins.fromJSON (builtins.readFile ../../src/hosts/Windows/users.json);

  assert' = cond: msg: if !cond then throw "ASSERTION FAILED: ${msg}" else null;

  test_posix_picard_ini_merge_overwrite_wiring = assert' (
    containsRegex "configurePicardSettings" homeText
    && containsRegex ''builtins\.readFile ./configs/picard/Picard\.ini'' homeText
    && containsRegex "_apply_picard_defaults_from_file" homeText
    && containsRegex "_upsert_ini_key" homeText
    && containsRegex "picardOverrideCommands" homeText
    && containsRegex ''renderPicardIniCommand "\$_picard_conf" "setting"'' homeText
    && containsRegex "Always preserve unmanaged keys and sections" homeText
  ) "home.nix must merge-overwrite managed Picard settings into native Picard.ini";

  test_windows_picard_ini_merge_overwrite_wiring =
    assert'
      (
        containsRegex "EnablePicardParity" windowsApplyText
        && containsRegex ''Sync-PicardConfig -Enabled:\$EnablePicardParity -Users \$selectedUserRecords -DefaultsFilePath \$picardDefaultsPath'' windowsApplyText
        && containsRegex "function Sync-PicardConfig" windowsPicardConfigText
        && containsRegex ''\[string\]\$DefaultsFilePath'' windowsPicardConfigText
        && containsRegex "Get-PicardDefaultPairsFromFile" windowsPicardConfigText
        && containsRegex "Get-PicardSettingOverride" windowsPicardConfigText
        && containsRegex ''AppData\\Roaming\\MusicBrainz\\Picard\.ini'' windowsPicardConfigText
        && containsRegex "_upsert_ini_key" windowsPicardConfigText
        && containsRegex "-Section 'setting'" windowsPicardConfigText
        && containsRegex "_remove_managed_ini_keys" windowsPicardConfigText
        && containsRegex "preserves all unmanaged" windowsPicardConfigText
        && containsRegex ''picard\s*=\s*ConvertTo-PlainObject'' windowsLoadUserRegistryText
      )
      "Windows apply path must converge Picard.ini via merge-overwrite module and user registry mapping";

  test_canonical_picard_defaults_file = assert' (
    containsRegex ''^\[application\]'' picardDefaultsIniText
    && containsRegex ''^version=2\.13\.3\.final0'' picardDefaultsIniText
    && containsRegex ''^\[profiles\]'' picardDefaultsIniText
    && containsRegex ''^\[setting\]'' picardDefaultsIniText
    && containsRegex ''^user_profiles=@Invalid\(\)'' picardDefaultsIniText
  ) "Canonical Picard defaults file must exist and include expected native INI sections";

  test_users_registry_exposes_picard_settings = assert' (
    builtins.hasAttr "picard" usersRegistry.polyipseity
    && builtins.hasAttr "settings" usersRegistry.polyipseity.picard
    && builtins.hasAttr "picard" windowsUsersRegistry.users.polyipseity
    && builtins.hasAttr "settings" windowsUsersRegistry.users.polyipseity.picard
  ) "Both POSIX and Windows user registries must expose picard.settings override maps";

  allTests = [
    test_posix_picard_ini_merge_overwrite_wiring
    test_windows_picard_ini_merge_overwrite_wiring
    test_canonical_picard_defaults_file
    test_users_registry_exposes_picard_settings
  ];
in
{
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} Picard config merge tests passed";
}
