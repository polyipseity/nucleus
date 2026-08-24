# Static assertions for the passwords-defaults policy implementation on MacBook.

let
  lib = import <nixpkgs/lib>;

  preferenceGcNix = builtins.readFile ../../../src/platforms/macOS/modules/preference-gc.nix;
  defaultsNix = builtins.readFile ../../../src/hosts/MacBook/defaults.nix;
  safariDefaultsSh = builtins.readFile ../../../src/platforms/macOS/scripts/macos-configure-safari-defaults.sh;
  macosDefaultNix = builtins.readFile ../../../src/platforms/macOS/modules/default.nix;
  # Path literals (not readFile) for files that may not exist yet — existence is
  # asserted via builtins.pathExists, and Nix `&&` short-circuits so the
  # readFile content check is only forced when the file is present.
  gcPreferencesShPath = ../../../src/platforms/macOS/scripts/macos-gc-preferences.sh;
  purgePreferencesShPath = ../../../src/platforms/macOS/scripts/macos-purge-preferences.sh;
  passwordsDefaultsShPath = ../../../src/platforms/macOS/scripts/macos-configure-passwords-defaults.sh;
in

# src/platforms/macOS/modules/preference-gc.nix — PassKit.policy registered (Phase 1)
assert lib.hasInfix "com.apple.PassKit.policy" preferenceGcNix;

# src/hosts/MacBook/defaults.nix — PassKit.policy block removed (Phase 2)
assert !lib.hasInfix "com.apple.PassKit.policy" defaultsNix;

# src/platforms/macOS/scripts/macos-configure-safari-defaults.sh — AutoFill flipped (Phase 3)
assert lib.hasInfix "AutoFillPasswords\" \"true\"" safariDefaultsSh;

# src/platforms/macOS/modules/default.nix — passwords-defaults script wired (Phase 5)
assert lib.hasInfix "macos-configure-passwords-defaults" macosDefaultNix;

# src/platforms/macOS/scripts/macos-configure-passwords-defaults.sh — created + contains policy (Phase 5)
assert
  builtins.pathExists passwordsDefaultsShPath
  && lib.hasInfix "com.apple.PassKit.policy" (builtins.readFile passwordsDefaultsShPath);

# src/platforms/macOS/scripts — gc-preferences renamed to purge-preferences (Phase 4)
# Old path gone (file absent + not referenced), new path present (file exists + referenced).
assert !builtins.pathExists gcPreferencesShPath;
assert !lib.hasInfix "macos-gc-preferences" macosDefaultNix;
assert builtins.pathExists purgePreferencesShPath;
assert lib.hasInfix "macos-purge-preferences" macosDefaultNix;

{
  success = true;
  message = "passwords-defaults policy tests passed";
}
