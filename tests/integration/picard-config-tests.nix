let
  homeText = builtins.readFile ../../src/modules/home.nix;
  linuxModuleText = builtins.readFile ../../src/modules/linux.nix;
  macosModuleText = builtins.readFile ../../src/modules/macos.nix;
  windowsApplyText = builtins.readFile ../../src/hosts/Windows/apply.ps1;
  windowsLoadUserRegistryText = builtins.readFile ../../src/hosts/Windows/modules/Load-UserRegistry.ps1;
  windowsPicardConfigText = builtins.readFile ../../src/hosts/Windows/modules/user/Sync-PicardConfig.ps1;
  picardDefaultsIniText = builtins.readFile ../../src/modules/configs/picard/Picard.ini;

  usersRegistry = builtins.fromJSON (builtins.readFile ../../src/modules/users.json);
  windowsUsersRegistry = builtins.fromJSON (builtins.readFile ../../src/hosts/Windows/users.json);

  inherit (import ../lib.nix) assert' containsRegex;

  test_posix_picard_ini_merge_overwrite_wiring = assert' (
    containsRegex "merge-picard-ini" homeText
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

  # AWK -v interprets escape sequences in its value argument, which corrupts
  # Picard's @Variant(\0\0\0\b…) serialized Qt values.  The fix passes value
  # through ENVIRON so AWK reads raw bytes without escape processing.
  test_posix_picard_ini_awk_environ_escape =
    assert'
      (
        containsRegex ''ENVIRON\["_UPSERT_VALUE"\]'' homeText
        && containsRegex "_UPSERT_VALUE.*_value" homeText
        && !containsRegex "-v value=.*_value" homeText
      )
      "home.nix _upsert_ini_key must pass value via ENVIRON to prevent AWK from interpreting Qt @Variant escape sequences";

  # On Linux, Picard's .desktop file registers audio MIME types.  Without
  # explicit xdg.mimeApps overrides the default handler depends on installation
  # order.  linux.nix must pin VLC as the default for all audio MIME types
  # that Picard claims so double-clicking audio opens the player, not the tagger.
  test_linux_audio_mime_handler_prevents_picard =
    assert'
      (
        containsRegex "xdg\.mimeApps" linuxModuleText
        && containsRegex "audio/mpeg" linuxModuleText
        && containsRegex "vlc\.desktop" linuxModuleText
      )
      "linux.nix must set VLC as default for audio MIME types to prevent Picard from claiming media file handlers";

  # Newly created build/cache directories inside iCloud-managed roots are not
  # excluded automatically.  A daily launchd agent runs iCloud exclusion
  # marking at 00:00 to close the drift window between home-manager activations.
  test_macos_icloud_exclusions_daily_schedule = assert' (
    containsRegex "icloud-exclusions" macosModuleText
    && containsRegex ''local\.icloud-exclusions'' macosModuleText
    && containsRegex "Hour = 0" macosModuleText
    && containsRegex "icloudExclusionsScript" macosModuleText
  ) "macos.nix must schedule iCloud exclusions as a daily launchd agent at 00:00";

  allTests = [
    test_posix_picard_ini_merge_overwrite_wiring
    test_windows_picard_ini_merge_overwrite_wiring
    test_canonical_picard_defaults_file
    test_users_registry_exposes_picard_settings
    test_posix_picard_ini_awk_environ_escape
    test_linux_audio_mime_handler_prevents_picard
    test_macos_icloud_exclusions_daily_schedule
  ];
in
builtins.seq (builtins.deepSeq allTests) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} Picard config merge tests passed";
}
