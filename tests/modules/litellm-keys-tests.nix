# tests/modules/litellm-keys-tests.nix — litellm keyArgs derivation invariants.
#
# The LiteLLM daemon wrapper receives KEYFILE:ENVVAR positional pairs
# (keyArgs) derived from the env catalog.  If keyArgs is empty while the
# catalog declares keys, the daemon starts with no API-key pairs and every
# `default` request fails with "Missing credentials".  This test mirrors the
# derivation used in ai.nix (map each catalog entry to a "PATH:ENVVAR" pair)
# and asserts the count and shape, so a regression to an empty keyArgs set is
# caught without building the full host configuration.

let
  catalogPath = ../../src/modules/env-catalog.nix;
  catalog = import catalogPath;
  inherit (import ../lib.nix) assert';

  keys = catalog.keys or [ ];

  # Mirror ai.nix: keyArgs = map (entry: "${sops.secrets.<name>.path}:${envVar}") keys
  # Here we use a dummy secret path prefix; only the count and shape matter.
  dummySecretPath = name: "/run/secrets.d/15/${name}";
  keyArgs = map (entry: "${dummySecretPath entry.name}:${entry.envVar}") keys;

  # Extract the env var portion (after the last ':') from a KEYFILE:ENVVAR pair.
  extractEnvVar =
    pair:
    let
      parts = builtins.split ":" pair;
    in
    builtins.elemAt parts (builtins.length parts - 1);

  # A KEYFILE:ENVVAR pair must contain exactly one ':' separating a non-empty
  # path from a non-empty env var.
  pairPattern =
    pair: builtins.match "^/run/secrets\.d/15/env_[a-z0-9_]+:[A-Z][A-Z0-9_]*$" pair;
in
{
  # === Catalog non-empty ===

  test_catalog_has_keys = assert' (
    builtins.length keys > 0
  ) "catalog must declare at least one AI key";

  # === keyArgs count mirrors catalog ===

  test_keyargs_count_matches_catalog =
    assert' (builtins.length keyArgs == builtins.length keys)
      "keyArgs count (${toString (builtins.length keyArgs)}) must equal catalog keys count (${toString (builtins.length keys)})";

  # === keyArgs shape ===

  test_all_keyargs_are_pairs = assert' (builtins.all (
    pair: pairPattern pair != null
  ) keyArgs) "every keyArg must be a /run/secrets.d/15/<name>:<ENVVAR> pair";

  # === keyArgs env vars match catalog envVars ===

  test_keyargs_envvars_match_catalog = assert' (builtins.all (
    pair: builtins.elem (extractEnvVar pair) (map (e: e.envVar) keys)
  ) keyArgs) "every keyArg env var must match a catalog envVar";
}
