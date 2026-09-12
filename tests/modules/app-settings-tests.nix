# tests/modules/app-settings-tests.nix — Validate managed app settings modules.
#
# Verifies QtPass and LibreOffice settings derivations produce correct output.
#
# Run with: nix-instantiate --eval tests/modules/app-settings-tests.nix

let
  lib = import <nixpkgs/lib>;
  pkgs = import <nixpkgs> { };
  inherit (lib) hasSuffix hasInfix;

  # --- QtPass settings ---
  qtpassModule = import ../../src/modules/configs/qtpass {
    inherit lib pkgs;
    passwordStoreDir = "/home/testuser/.password-store";
    qtPassDefaultSettings = {
      useGit = true;
      hidePassword = true;
    };
  };

  managed = qtpassModule.qtPassManagedSettings;
  gpgExe = lib.getExe pkgs.gnupg;

  test_qtpass_gpgExecutable_present = managed ? gpgExecutable;
  test_qtpass_gpgExecutable_is_managed = managed.gpgExecutable == gpgExe;
  test_qtpass_gpgExecutable_points_at_gnupg = hasInfix "gnupg" managed.gpgExecutable;
  test_qtpass_gpgExecutable_is_bin_gpg = hasSuffix "/bin/gpg" managed.gpgExecutable;
  test_qtpass_passStore_derived = managed.passStore == "/home/testuser/.password-store/";
  test_qtpass_darwin_command_emits_gpg = hasInfix "gpgExecutable" qtpassModule.qtPassDarwinCommands;

  # --- LibreOffice settings ---
  # Full settings enabled.
  fullModule = import ../../src/modules/configs/libreoffice/libreoffice.nix {
    inherit lib;
    libreOfficeDefaultSettings = {
      removePersonalInfoOnSave = true;
      clearUserProfileData = true;
      extraSettings = [
        {
          path = "/org.openoffice.Office.Common/Security/Scripting";
          name = "Foo";
          value = "bar";
        }
      ];
    };
  };

  # Only personal info removal, no user data clearing.
  partialModule = import ../../src/modules/configs/libreoffice/libreoffice.nix {
    inherit lib;
    libreOfficeDefaultSettings = {
      removePersonalInfoOnSave = true;
      clearUserProfileData = false;
      extraSettings = [ ];
    };
  };

  # Nothing enabled.
  disabledModule = import ../../src/modules/configs/libreoffice/libreoffice.nix {
    inherit lib;
    libreOfficeDefaultSettings = {
      removePersonalInfoOnSave = false;
      clearUserProfileData = false;
      extraSettings = [ ];
    };
  };

  fullEntries = fullModule.libreOfficeManagedXcuEntries;
  partialEntries = partialModule.libreOfficeManagedXcuEntries;
  disabledEntries = disabledModule.libreOfficeManagedXcuEntries;

  # Full module: 1 RemovePersonalInfoOnSave + 19 profile fields + 1 extra = 21
  test_libre_full_entry_count = builtins.length fullEntries == 21;
  test_libre_full_has_remove_personal = builtins.any (e: e.name == "RemovePersonalInfoOnSaving") fullEntries;
  test_libre_full_scripting_path = builtins.any (
    e:
    e.path == "/org.openoffice.Office.Common/Security/Scripting"
    && e.name == "RemovePersonalInfoOnSaving"
    && e.value == "true"
  ) fullEntries;
  test_libre_full_profile_path = builtins.all (e: e.path == "/org.openoffice.UserProfile/Data") (
    builtins.filter (e: e.name != "RemovePersonalInfoOnSaving" && e.name != "Foo") fullEntries
  );
  test_libre_full_extra_appended = builtins.any (e: e.name == "Foo" && e.value == "bar") fullEntries;

  # Partial module: 1 RemovePersonalInfoOnSave + 0 profile + 0 extra = 1
  test_libre_partial_entry_count = builtins.length partialEntries == 1;
  test_libre_partial_has_remove_personal = builtins.any (
    e: e.name == "RemovePersonalInfoOnSaving"
  ) partialEntries;
  test_libre_partial_no_profile_fields =
    builtins.length (builtins.filter (e: e.path == "/org.openoffice.UserProfile/Data") partialEntries)
    == 0;

  # Disabled module
  test_libre_disabled_no_entries = builtins.length disabledEntries == 0;

  # Merge args
  test_libre_full_merge_args_nonempty = fullModule.libreOfficeMergeArgs != "";
  test_libre_full_merge_args_has_remove = hasInfix "RemovePersonalInfoOnSaving" fullModule.libreOfficeMergeArgs;
  test_libre_full_merge_args_has_extra = hasInfix "bar" fullModule.libreOfficeMergeArgs;

  # XCU paths
  test_libre_darwin_path =
    fullModule.libreOfficeDarwinXcuPath
    == "$HOME/Library/Application Support/LibreOffice/4/user/registrymodifications.xcu";
  test_libre_linux_path =
    fullModule.libreOfficeLinuxXcuPath == "$HOME/.config/libreoffice/4/user/registrymodifications.xcu";
in
{
  success =
    test_qtpass_gpgExecutable_present
    && test_qtpass_gpgExecutable_is_managed
    && test_qtpass_gpgExecutable_points_at_gnupg
    && test_qtpass_gpgExecutable_is_bin_gpg
    && test_qtpass_passStore_derived
    && test_qtpass_darwin_command_emits_gpg
    && test_libre_full_entry_count
    && test_libre_full_has_remove_personal
    && test_libre_full_scripting_path
    && test_libre_full_profile_path
    && test_libre_full_extra_appended
    && test_libre_partial_entry_count
    && test_libre_partial_has_remove_personal
    && test_libre_partial_no_profile_fields
    && test_libre_disabled_no_entries
    && test_libre_full_merge_args_nonempty
    && test_libre_full_merge_args_has_remove
    && test_libre_full_merge_args_has_extra
    && test_libre_darwin_path
    && test_libre_linux_path;
  message = "App settings tests passed";
}
