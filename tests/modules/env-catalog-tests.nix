# tests/modules/env-catalog-tests.nix — env-catalog.nix invariants.
#
# Validates the catalog structure, key patterns, env var derivation,
# uniqueness, and schema compliance.  The catalog is the static source of
# truth for all hosts, consumed by env-catalog-sops.nix (NixOS/darwin) and
# ai.nix (keyArgs derivation).
#
# Includes cross-check: every os.environ/VAR referenced in litellm-config.yml
# must appear in the catalog's envVar values.  Prevents stale config after
# catalog edits.

let
  catalogPath = ../../src/modules/env-catalog.nix;
  catalog = import catalogPath;
  inherit (import ../lib.nix) assert';

  keys = catalog.keys or [ ];

  # Pattern: name must match env_ prefix + lowercase alphanumeric + underscores
  namePattern = builtins.match "^env_[a-z0-9_]+$";

  # Pattern: envVar must be valid env var name (uppercase + digits + underscores)
  envVarPattern = builtins.match "^[A-Z][A-Z0-9_]*$";

  # builtins.unique unavailable in pure eval; manual dedup via foldl'.
  uniqueNames = builtins.foldl' (acc: k: if builtins.elem k acc then acc else acc ++ [ k ]) [ ] (
    map (e: e.name) keys
  );

  # Cross-check: every os.environ/VAR referenced in litellm-config.yml must
  # be in the catalog's envVar values.
  litellmConfig = builtins.readFile ../../src/modules/ai/litellm-config.yml;
  lines = builtins.split "\n" litellmConfig;
  stringLines = builtins.filter builtins.isString lines;
  extractEnvVar =
    line:
    let
      m = builtins.match ".*os\\.environ/([A-Z][A-Z0-9_]+).*" line;
    in
    if m != null then builtins.head m else null;
  envRefs = builtins.filter (m: m != null) (builtins.map extractEnvVar stringLines);
in
{
  # === Catalog structure ===

  test_catalog_has_keys_field = assert' (catalog ? keys) "catalog must have a keys field";

  test_keys_is_list = assert' (builtins.isList keys) "keys must be a list";

  test_all_entries_are_objects = assert' (builtins.all (
    e: builtins.isAttrs e
  ) keys) "every entry must be an object";

  test_all_entries_have_name_and_envvar = assert' (builtins.all (
    e: e ? name && e ? envVar
  ) keys) "every entry must have name and envVar fields";

  # === Name pattern validation ===

  test_all_names_match_pattern = assert' (builtins.all (
    e: namePattern e.name != null
  ) keys) "all names must match env_key_<provider> pattern";

  # === EnvVar pattern validation ===

  test_all_envvars_match_pattern = assert' (builtins.all (
    e: envVarPattern e.envVar != null
  ) keys) "all envVar values must match uppercase env var pattern";

  # === Uniqueness ===

  test_no_duplicate_names = assert' (
    builtins.length uniqueNames == builtins.length keys
  ) "key names must have no duplicates";

  # === Expected key count and providers ===

  test_key_count = assert' (builtins.length keys == 8) "catalog must contain exactly 8 keys";

  test_expected_providers_present = assert' (builtins.all
    (expected: builtins.any (e: e.name == expected.name && e.envVar == expected.envVar) keys)
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
    ]
  ) "all 8 expected keys with correct envVar mappings must be present";

  # === Cross-check: litellm-config.yml env refs vs catalog ===

  test_litellm_config_env_refs_in_catalog = assert' (builtins.all (
    ref: builtins.elem ref (map (e: e.envVar) keys)
  ) envRefs) "all os.environ/ vars in litellm-config.yml must be present in catalog";
}
