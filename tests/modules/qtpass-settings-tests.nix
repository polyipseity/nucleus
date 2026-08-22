# tests/modules/qtpass-settings-tests.nix — Validate QtPass managed settings.
#
# Verifies:
#   • Module imports cleanly and emits a deterministic gpgExecutable
#   • gpgExecutable points at the managed gnupg package (not a stale hash)
#   • passStore is derived from the resolved password store dir
#
# Run with: nix-instantiate --eval tests/modules/qtpass-settings-tests.nix

let
  lib = import <nixpkgs/lib>;
  pkgs = import <nixpkgs> { };
  inherit (lib) hasSuffix hasInfix;

  qtpassModule = import ../../src/modules/configs/qtpass/qtpass.nix {
    inherit lib pkgs;
    passwordStoreDir = "/home/testuser/.password-store";
    qtPassDefaultSettings = {
      useGit = true;
      hidePassword = true;
    };
  };

  managed = qtpassModule.qtPassManagedSettings;

  gpgExe = lib.getExe pkgs.gnupg;

  test_gpgExecutable_present = managed ? gpgExecutable;
  test_gpgExecutable_is_managed = managed.gpgExecutable == gpgExe;
  test_gpgExecutable_points_at_gnupg = hasInfix "gnupg" managed.gpgExecutable;
  test_gpgExecutable_is_bin_gpg = hasSuffix "/bin/gpg" managed.gpgExecutable;
  test_passStore_derived = managed.passStore == "/home/testuser/.password-store/";
  test_darwin_command_emits_gpg = hasInfix "gpgExecutable" qtpassModule.qtPassDarwinCommands;
in
{
  success =
    test_gpgExecutable_present
    && test_gpgExecutable_is_managed
    && test_gpgExecutable_points_at_gnupg
    && test_gpgExecutable_is_bin_gpg
    && test_passStore_derived
    && test_darwin_command_emits_gpg;
  message = "QtPass settings tests passed";
}
