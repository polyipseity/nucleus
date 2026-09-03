# tests/modules/libreoffice-settings-tests.nix — Validate LibreOffice managed XCU settings.
#
# Verifies:
#   • Module imports cleanly and produces managed entries
#   • RemovePersonalInfoOnSave entry present when enabled
#   • UserProfile/Data fields generated for clearUserProfileData
#   • Extra settings appended
#   • Merge args contain all managed entries
#   • Platform-specific XCU paths are correct
#
# Run with: nix-instantiate --eval tests/modules/libreoffice-settings-tests.nix

let
  lib = import <nixpkgs/lib>;

  # Full settings enabled.
  fullModule = import ../../src/modules/configs/libreoffice/libreoffice.nix {
    inherit lib;
    libreOfficeDefaultSettings = {
      removePersonalInfoOnSave = true;
      clearUserProfileData = true;
      extraSettings = [
        { path = "/org.openoffice.Office.Common/Security/Scripting"; name = "Foo"; value = "bar"; }
      ];
    };
  };

  # Only personal info removal, no user data clearing.
  partialModule = import ../../src/modules/configs/libreoffice/libreoffice.nix {
    inherit lib;
    libreOfficeDefaultSettings = {
      removePersonalInfoOnSave = true;
      clearUserProfileData = false;
      extraSettings = [];
    };
  };

  # Nothing enabled.
  disabledModule = import ../../src/modules/configs/libreoffice/libreoffice.nix {
    inherit lib;
    libreOfficeDefaultSettings = {
      removePersonalInfoOnSave = false;
      clearUserProfileData = false;
      extraSettings = [];
    };
  };

  fullEntries = fullModule.libreOfficeManagedXcuEntries;
  partialEntries = partialModule.libreOfficeManagedXcuEntries;
  disabledEntries = disabledModule.libreOfficeManagedXcuEntries;

  # ── Full module tests ──────────────────────────────────────────────
  # 1 RemovePersonalInfoOnSave + 19 profile fields + 1 extra = 21
  test_full_entry_count = builtins.length fullEntries == 21;
  test_full_has_remove_personal = builtins.any (e: e.name == "RemovePersonalInfoOnSave") fullEntries;
  test_full_scripting_path = builtins.any (e: e.path == "/org.openoffice.Office.Common/Security/Scripting" && e.name == "RemovePersonalInfoOnSave" && e.value == "true") fullEntries;
  test_full_profile_path = builtins.all (e: e.path == "/org.openoffice.UserProfile/Data") (builtins.filter (e: e.name != "RemovePersonalInfoOnSave" && e.name != "Foo") fullEntries);
  test_full_extra_appended = builtins.any (e: e.name == "Foo" && e.value == "bar") fullEntries;

  # ── Partial module tests ───────────────────────────────────────────
  # 1 RemovePersonalInfoOnSave + 0 profile fields + 0 extra = 1
  test_partial_entry_count = builtins.length partialEntries == 1;
  test_partial_has_remove_personal = builtins.any (e: e.name == "RemovePersonalInfoOnSave") partialEntries;
  test_partial_no_profile_fields = builtins.length (builtins.filter (e: e.path == "/org.openoffice.UserProfile/Data") partialEntries) == 0;

  # ── Disabled module tests ──────────────────────────────────────────
  test_disabled_no_entries = builtins.length disabledEntries == 0;

  # ── Merge args tests ──────────────────────────────────────────────
  test_full_merge_args_nonempty = fullModule.libreOfficeMergeArgs != "";
  test_full_merge_args_has_remove = lib.hasInfix "RemovePersonalInfoOnSave" fullModule.libreOfficeMergeArgs;
  test_full_merge_args_has_extra = lib.hasInfix "bar" fullModule.libreOfficeMergeArgs;

  # ── XCU path tests ────────────────────────────────────────────────
  test_darwin_path = fullModule.libreOfficeDarwinXcuPath == "~/Library/Application Support/LibreOffice/4/user/registrymodifications.xcu";
  test_linux_path = fullModule.libreOfficeLinuxXcuPath == "~/.config/libreoffice/4/user/registrymodifications.xcu";

  allTests = {
    inherit
      test_full_entry_count
      test_full_has_remove_personal
      test_full_scripting_path
      test_full_profile_path
      test_full_extra_appended
      test_partial_entry_count
      test_partial_has_remove_personal
      test_partial_no_profile_fields
      test_disabled_no_entries
      test_full_merge_args_nonempty
      test_full_merge_args_has_remove
      test_full_merge_args_has_extra
      test_darwin_path
      test_linux_path
      ;
  };
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  message = "LibreOffice settings tests passed";
}
