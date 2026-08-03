# UTM renderer-backend provisioning tests.
#
# Verifies that the UTM Apple Core OpenGL (CGL) renderer pref script exists,
# is referenced in activation.nix, and writes the QEMURendererBackend key
# through the console-user pattern.

let
  lib = import <nixpkgs/lib>;

  activationNix = builtins.readFile ../../../src/hosts/MacBook/activation.nix;
  utmRendererSh = builtins.readFile ../../../src/scripts/hosts/MacBook/macos-set-utm-renderer.sh;
in

# activation.nix references the UTM renderer script
assert lib.hasInfix "configure-utm-renderer-prefs" activationNix;
assert lib.hasInfix "macos-set-utm-renderer.sh" activationNix;

# Script writes the Apple Core OpenGL (CGL) renderer key through the
# console-user pattern
assert lib.hasInfix "QEMURendererBackend" utmRendererSh;
assert lib.hasInfix "macos-console-user.sh" utmRendererSh;
assert lib.hasInfix "launchctl asuser" utmRendererSh;
assert lib.hasInfix "-int 3" utmRendererSh;

# Script targets the sandboxed UTM container
assert lib.hasInfix "Library/Containers/com.utmapp.UTM" utmRendererSh;

{
  success = true;
  message = "utm-renderer tests passed";
}
