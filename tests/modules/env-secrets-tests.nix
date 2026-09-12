# tests/modules/env-secrets-tests.nix — env/env-secrets.json invariants.
#
# Validates the secrets structure, consumer scoping, sopsSource split,
# name patterns, env var derivation, uniqueness, and schema compliance.
# Also validates LiteLLM secretArgs derivation shape from the same catalog.
#
# The env-secrets catalog is the static source of truth for all hosts,
# consumed by env-secrets-sops.nix (NixOS/darwin) and ai.nix (secretArgs).

let
  secretsPath = ../../src/modules/env/env-secrets.json;
  secrets = builtins.fromJSON (builtins.readFile secretsPath);
  inherit (import ../lib.nix) assert';

  entries = secrets.secrets or [ ];

  # Pattern: envVar must be valid env var name (uppercase + digits + underscores)
  envVarPattern = builtins.match "^[A-Z][A-Z0-9_]*$";

  # builtins.unique unavailable in pure eval; manual dedup via foldl'.
  uniqueNames = builtins.foldl' (acc: k: if builtins.elem k acc then acc else acc ++ [ k ]) [ ] (
    map (e: e.name) entries
  );

  # Consumer-filtered subsets.
  hermesSecrets = builtins.filter (s: builtins.elem "hermes-agent" s.consumers) entries;
  litellmEntries = builtins.filter (s: builtins.elem "litellm" s.consumers) entries;

  # LiteLLM secretArgs derivation (mirrors ai.nix).
  dummySecretPath = name: "/run/secrets.d/15/${name}";
  secretArgs = map (entry: "${dummySecretPath entry.name}:${entry.envVar}") litellmEntries;
  extractEnvVar =
    pair:
    let
      parts = builtins.split ":" pair;
    in
    builtins.elemAt parts (builtins.length parts - 1);
  pairPattern = pair: builtins.match "^/run/secrets\\.d/15/[a-z0-9_]+:[A-Z][A-Z0-9_]*$" pair;

in
{
  # === Schema structure ===

  test_has_secrets_field = assert' (secrets ? secrets) "env-secrets must have a secrets field";

  test_secrets_is_list = assert' (builtins.isList entries) "secrets must be a list";

  test_all_entries_are_objects = assert' (builtins.all (
    e: builtins.isAttrs e
  ) entries) "every entry must be an object";

  test_all_entries_have_required_fields = assert' (builtins.all (
    e: e ? name && e ? envVar && e ? sopsSource && e ? consumers
  ) entries) "every entry must have name, envVar, sopsSource, and consumers fields";

  # === EnvVar pattern validation ===

  test_all_envvars_match_pattern = assert' (builtins.all (
    e: envVarPattern e.envVar != null
  ) entries) "all envVar values must match uppercase env var pattern";

  # === sopsSource validation ===

  test_all_sops_source_valid = assert' (builtins.all (
    e: e.sopsSource == "system" || e.sopsSource == "user"
  ) entries) "all sopsSource values must be 'system' or 'user'";

  # === consumers validation ===

  test_all_consumers_are_lists = assert' (builtins.all (
    e: builtins.isList e.consumers
  ) entries) "all consumers fields must be lists";

  # === Uniqueness ===

  test_no_duplicate_names = assert' (
    builtins.length uniqueNames == builtins.length entries
  ) "secret names must have no duplicates";

  # === Expected key count and providers ===

  test_key_count = assert' (
    builtins.length entries == 9
  ) "env-secrets must contain exactly 9 entries";

  test_expected_providers_present = assert' (builtins.all
    (expected: builtins.any (e: e.name == expected.name && e.envVar == expected.envVar) entries)
    [
      {
        name = "env_key_ai_cline";
        envVar = "KEY_AI_CLINE";
      }
      {
        name = "env_key_ai_command_code";
        envVar = "KEY_AI_COMMAND_CODE";
      }
      {
        name = "env_key_ai_opencode_go";
        envVar = "KEY_AI_OPENCODE_GO";
      }
      {
        name = "env_key_ai_opencode_go_1";
        envVar = "KEY_AI_OPENCODE_GO_1";
      }
      {
        name = "env_key_ai_opencode_zen";
        envVar = "KEY_AI_OPENCODE_ZEN";
      }
      {
        name = "env_key_ai_opencode_zen_1";
        envVar = "KEY_AI_OPENCODE_ZEN_1";
      }
      {
        name = "env_key_ai_openrouter";
        envVar = "KEY_AI_OPENROUTER";
      }
      {
        name = "env_redis_password";
        envVar = "REDIS_PASSWORD";
      }
      {
        name = "env_redis_user_litellm_password";
        envVar = "REDIS_USER_LITELLM_PASSWORD";
      }
    ]
  ) "all 9 expected entries with correct envVar mappings must be present";

  # === Consumer scoping ===

  test_all_system_entries_consumed_by_litellm = assert' (builtins.all
    (e: builtins.elem "litellm" e.consumers)
    (builtins.filter (e: e.sopsSource == "system") entries)
  ) "all system entries must be consumed by litellm";

  test_hermes_secrets_empty_by_default = assert' (
    builtins.length hermesSecrets == 0
  ) "no hermes-agent consumer entries by default (user opt-in)";

  # === sopsSource split ===

  test_system_secrets_nonempty = assert' (
    builtins.length (builtins.filter (e: e.sopsSource == "system") entries) > 0
  ) "must have at least one system sopsSource entry";

  test_user_secrets_empty_by_default = assert' (
    builtins.length (builtins.filter (e: e.sopsSource == "user") entries) == 0
  ) "no user sopsSource entries by default (user opt-in)";

  # === LiteLLM secretArgs derivation ===

  test_secretargs_count_matches_litellm =
    assert' (builtins.length secretArgs == builtins.length litellmEntries)
      "secretArgs count (${toString (builtins.length secretArgs)}) must equal litellm consumer count (${toString (builtins.length litellmEntries)})";

  test_all_secretargs_are_pairs = assert' (builtins.all (
    pair: pairPattern pair != null
  ) secretArgs) "every secretArg must be a /run/secrets.d/15/<name>:<ENVVAR> pair";

  test_secretargs_envvars_match_catalog = assert' (builtins.all (
    pair: builtins.elem (extractEnvVar pair) (map (e: e.envVar) entries)
  ) secretArgs) "every secretArg env var must match a catalog envVar";
}
