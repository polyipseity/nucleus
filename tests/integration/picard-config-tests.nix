let
  homeText = builtins.readFile ../../src/modules/home.nix;
  linuxModuleText = builtins.readFile ../../src/modules/linux.nix;
  macosModuleText = builtins.readFile ../../src/modules/macos.nix;
  windowsApplyText = builtins.readFile ../../src/hosts/Windows/apply.ps1;
  windowsPicardConfigText = builtins.readFile ../../src/hosts/Windows/modules/user/Sync-PicardConfig.ps1;
  picardDefaultsIniText = builtins.readFile ../../src/users/default/picard/Picard.ini;
  picardMergeScriptText = builtins.readFile ../../src/scripts/configs/merge-picard-ini.sh;
  picardMergeAwkText = builtins.readFile ../../src/scripts/configs/merge-picard-ini.awk;
  usersOverlayText = builtins.readFile ../../src/modules/lib/users-overlay.nix;

  inherit (import ../lib.nix) assert' containsRegex;

  test_posix_picard_ini_merge_overwrite_wiring = assert' (
    containsRegex "merge-picard-ini" homeText
    && containsRegex "selectUserAppConfigFile \"picard\" \"Picard.ini\"" homeText
    && containsRegex "_apply_picard_defaults_from_file" picardMergeScriptText
    && containsRegex "Always preserve unmanaged keys and sections" homeText
  ) "home.nix must merge-overwrite managed Picard settings into native Picard.ini";

  test_windows_picard_ini_merge_overwrite_wiring = assert' (
    containsRegex "EnablePicardParity" windowsApplyText
    && containsRegex ''Sync-PicardConfig -Enabled:\$EnablePicardParity -Users \$selectedUserRecords -RepoRoot \$repoRoot'' windowsApplyText
    && containsRegex "function Sync-PicardConfig" windowsPicardConfigText
    && containsRegex "Resolve-UserConfigFile" windowsPicardConfigText
    && containsRegex "Get-PicardDefaultPairsFromFile" windowsPicardConfigText
    && containsRegex ''AppData\\Roaming\\MusicBrainz\\Picard\.ini'' windowsPicardConfigText
    && containsRegex "_upsert_ini_key" windowsPicardConfigText
    && containsRegex "_remove_managed_ini_keys" windowsPicardConfigText
    && containsRegex "unmanaged keys/sections" windowsPicardConfigText
  ) "Windows apply path must converge Picard.ini via merge-overwrite module";

  test_canonical_picard_defaults_file = assert' (
    containsRegex "[[]application[]]" picardDefaultsIniText
    && containsRegex ''version=2\.13\.3\.final0'' picardDefaultsIniText
    && containsRegex "[[]profiles[]]" picardDefaultsIniText
    && containsRegex "[[]setting[]]" picardDefaultsIniText
    && containsRegex ''user_profiles=@Invalid\(\)'' picardDefaultsIniText
  ) "Canonical Picard defaults file must exist and include expected native INI sections";

  test_users_overlay_exposes_picard_selector = assert' (containsRegex "selectUserConfigFile" usersOverlayText) "users-overlay.nix must expose selectUserConfigFile for per-user Picard baselines";

  test_posix_picard_ini_awk_environ_escape =
    assert'
      (
        containsRegex ''ENVIRON[[]"_UPSERT_VALUE"[]]'' picardMergeAwkText
        && containsRegex ''value = ENVIRON[[]"_UPSERT_VALUE"[]]'' picardMergeAwkText
        && !containsRegex "-v value=.*_value" picardMergeScriptText
      )
      "merge-picard-ini.sh _upsert_ini_key must pass value via ENVIRON to prevent AWK from interpreting Qt @Variant escape sequences";

  test_linux_audio_mime_handler_prevents_picard =
    assert'
      (
        containsRegex "xdg\.mimeApps" linuxModuleText
        && containsRegex "audio/mpeg" linuxModuleText
        && containsRegex "vlc\.desktop" linuxModuleText
      )
      "linux.nix must set VLC as default for audio MIME types to prevent Picard from claiming media file handlers";

  test_macos_icloud_exclusions_daily_schedule = assert' (
    containsRegex "icloud-exclusions" macosModuleText
    && containsRegex ''local\.icloud-exclusions'' macosModuleText
    && containsRegex "StartInterval = 3600;" macosModuleText
    && containsRegex "icloudExclusionsScript" macosModuleText
  ) "macos.nix must schedule iCloud exclusions as a recurring launchd agent";

  allTests = [
    test_posix_picard_ini_merge_overwrite_wiring
    test_windows_picard_ini_merge_overwrite_wiring
    test_canonical_picard_defaults_file
    test_users_overlay_exposes_picard_selector
    test_posix_picard_ini_awk_environ_escape
    test_linux_audio_mime_handler_prevents_picard
    test_macos_icloud_exclusions_daily_schedule
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} Picard config merge tests passed";
}
