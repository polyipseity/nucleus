# tests/modules/pi-bunfig-tests.nix — Validate pi bunfig.toml configuration.
#
# Verifies:
#   • src/users/default/pi/bunfig.toml exists
#   • linker = "hoisted" is set for extension compatibility
#   • exact = true is set for reproducible installs
#
# Run with: nix-instantiate --eval tests/modules/pi-bunfig-tests.nix

let
  inherit (import ../lib.nix) assert' containsRegex;

  bunfigPath = ../../src/users/default/pi/bunfig.toml;
  bunfigContent = builtins.readFile bunfigPath;

  # --- Linker setting ---
  hasHoistedLinker = containsRegex "linker = \"hoisted\"" bunfigContent;

  # --- Exact install setting ---
  hasExactTrue = containsRegex "exact = true" bunfigContent;

  # --- Sanity: not empty ---
  isNonEmpty = builtins.stringLength bunfigContent > 0;
in
{
  # bunfig.toml exists and is non-empty
  test_bunfig_is_nonempty = assert' isNonEmpty "pi bunfig.toml must exist and be non-empty";

  # Linker must be hoisted for extension compatibility
  test_linker_is_hoisted = assert' hasHoistedLinker "pi bunfig.toml must set linker = \"hoisted\" for extension compatibility";

  # Exact installs enabled
  test_exact_is_true = assert' hasExactTrue "pi bunfig.toml must set exact = true for reproducible installs";

  # Overall
  success = isNonEmpty && hasHoistedLinker && hasExactTrue;
}
