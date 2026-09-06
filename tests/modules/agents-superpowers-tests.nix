# tests/modules/agents-superpowers-tests.nix — Validate superpowers provisioning.
#
# Verifies:
#   • lockfile.cursor.superpowers exists with source (URI) and rev (hex hash)
#   • builtins.fetchGit evaluates to a Nix store path
#
# Run with: nix-instantiate --eval tests/modules/agents-superpowers-tests.nix

let
  inherit (import ../lib.nix) assert';

  lockfile = builtins.fromJSON (builtins.readFile ../../src/lockfiles/lockfile.json);

  # --- Lockfile structure ---
  hasCursor = lockfile ? cursor;
  hasSuperpowers = hasCursor && lockfile.cursor ? superpowers;
  sp = lockfile.cursor.superpowers or { };
  hasSource = sp ? source;
  hasRev = sp ? rev;

  sourceIsUri = hasSource && builtins.match "https://.*" sp.source != null;
  revIsHex = hasRev && builtins.match "[0-9a-f]{40}" sp.rev != null;

  # --- builtins.fetchGit ---
  # Evaluates at Nix build time; produces a /nix/store/ path.
  superpowersSrc = builtins.fetchGit {
    url = sp.source;
    rev = sp.rev;
    submodules = false;
  };
  srcPath = builtins.storePath superpowersSrc;
  srcIsInStore = builtins.substring 0 10 srcPath == "/nix/store";
in
{
  # Lockfile structure
  test_cursor_section_exists = assert' hasCursor "lockfile must have a cursor section";
  test_cursor_superpowers_exists = assert' hasSuperpowers "cursor must have a superpowers entry";
  test_source_is_uri = assert' sourceIsUri "source must be an https URI";
  test_rev_is_hex = assert' revIsHex "rev must be a 40-char hex git hash";

  # builtins.fetchGit evaluation
  test_store_path_is_in_nix_store = assert' srcIsInStore "store path must start with /nix/store/";

  # Overall
  all_tests_pass = hasCursor && hasSuperpowers && sourceIsUri && revIsHex && srcIsInStore;
  success = hasCursor && hasSuperpowers && sourceIsUri && revIsHex && srcIsInStore;
}
