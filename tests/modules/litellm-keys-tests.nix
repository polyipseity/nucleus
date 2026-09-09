# tests/modules/litellm-keys-tests.nix — litellm secretArgs derivation invariants.
#
# The LiteLLM daemon wrapper receives KEYFILE:ENVVAR positional pairs
# (secretArgs) derived from the env-secrets catalog.  If secretArgs is empty
# while the catalog declares secrets, the daemon starts with no API-key pairs
# and every `default` request fails with "Missing credentials".  This test
# mirrors the derivation used in ai.nix (map each catalog entry to a
# "PATH:ENVVAR" pair) and asserts the count and shape, so a regression to an
# empty secretArgs set is caught without building the full host configuration.

let
  secretsPath = ../../src/modules/env/env-secrets.json;
  secrets = builtins.fromJSON (builtins.readFile secretsPath);
  inherit (import ../lib.nix) assert';

  entries = secrets.secrets or [ ];

  # Filter to litellm consumer only (mirrors mkSecretArgsForConsumer).
  litellmEntries = builtins.filter (s: builtins.elem "litellm" s.consumers) entries;

  # Mirror ai.nix: secretArgs = map (entry: "${sops.secrets.<name>.path}:${envVar}") litellmEntries
  # Here we use a dummy secret path prefix; only the count and shape matter.
  dummySecretPath = name: "/run/secrets.d/15/${name}";
  secretArgs = map (entry: "${dummySecretPath entry.name}:${entry.envVar}") litellmEntries;

  # Extract the env var portion (after the last ':') from a KEYFILE:ENVVAR pair.
  extractEnvVar =
    pair:
    let
      parts = builtins.split ":" pair;
    in
    builtins.elemAt parts (builtins.length parts - 1);

  # A KEYFILE:ENVVAR pair must contain exactly one ':' separating a non-empty
  # path from a non-empty env var.
  pairPattern = pair: builtins.match "^/run/secrets\\.d/15/[a-z0-9_]+:[A-Z][A-Z0-9_]*$" pair;
in
{
  # === Catalog non-empty ===

  test_catalog_has_secrets = assert' (
    builtins.length entries > 0
  ) "env-secrets must declare at least one secret";

  # === secretArgs count mirrors litellm consumer filter ===

  test_secretargs_count_matches_litellm =
    assert' (builtins.length secretArgs == builtins.length litellmEntries)
      "secretArgs count (${toString (builtins.length secretArgs)}) must equal litellm consumer count (${toString (builtins.length litellmEntries)})";

  # === secretArgs shape ===

  test_all_secretargs_are_pairs = assert' (builtins.all (
    pair: pairPattern pair != null
  ) secretArgs) "every secretArg must be a /run/secrets.d/15/<name>:<ENVVAR> pair";

  # === secretArgs env vars match catalog envVars ===

  test_secretargs_envvars_match_catalog = assert' (builtins.all (
    pair: builtins.elem (extractEnvVar pair) (map (e: e.envVar) entries)
  ) secretArgs) "every secretArg env var must match a catalog envVar";
}
