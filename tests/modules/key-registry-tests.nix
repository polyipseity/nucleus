# tests/modules/key-registry-tests.nix — key-registry.nix invariants.
#
# Validates that the AI key registry maps SOPS key names to env var names
# correctly and contains no duplicates or malformed entries.

let
  registry = import ../../src/modules/ai/key-registry.nix;
  inherit (import ../lib.nix) assert';

  registryKeys = builtins.attrNames registry;
  registryValues = builtins.attrValues registry;

  # Pattern: keys must match ai_<provider>_api_key
  keyPattern = builtins.match "^ai_[a-z0-9_]+_api_key$";

  # Pattern: values must be valid env var names (uppercase + digits + underscores)
  envVarPattern = builtins.match "^[A-Z][A-Z0-9_]*$";

  # All 4 expected providers.
  expectedProviders = [
    "ai_command_code_api_key"
    "ai_openrouter_api_key"
    "ai_opencode_go_api_key"
    "ai_opencode_zen_api_key"
  ];

  # builtins.unique unavailable in pure eval; manual dedup via foldl'.
  uniqueValues = builtins.foldl' (
    acc: v: if builtins.elem v acc then acc else acc ++ [ v ]
  ) [ ] registryValues;

  # Cross-check: every os.environ/VAR referenced in litellm-config.yml must
  # be in the key-registry values.  Prevents stale config after registry edits.
  litellmConfig = builtins.readFile ../../src/modules/ai/litellm-config.yml;
  # builtins.match is anchored — strip each line, then filter for env refs.
  lines = builtins.split "\n" litellmConfig;
  # builtins.split alternates non-matching chunks and matching groups (as lists).
  # Extract only string lines, then match each for os.environ/VAR.
  isStringOrEmpty = s: builtins.isString s;
  stringLines = builtins.filter isStringOrEmpty lines;
  extractEnvVar =
    line:
    let
      m = builtins.match ".*os\\.environ/([A-Z][A-Z0-9_]+).*" line;
    in
    if m != null then builtins.head m else null;
  envRefs = builtins.filter (m: m != null) (builtins.map extractEnvVar stringLines);
in
{
  # === Structural invariants ===

  test_registry_is_attrset = assert' (builtins.isAttrs registry) "key-registry must be an attrset";

  test_registry_has_exactly_4_entries = assert' (
    builtins.length registryKeys == 4
  ) "key-registry must have exactly 4 entries";

  test_all_expected_providers_present = assert' (builtins.all (
    k: builtins.elem k registryKeys
  ) expectedProviders) "all 4 expected provider keys must be present";

  # === Key name validation ===

  test_all_keys_match_pattern = assert' (builtins.all (
    k: keyPattern k != null
  ) registryKeys) "all keys must match ai_<provider>_api_key pattern";

  # === Value validation ===

  test_all_values_are_nonempty_strings = assert' (builtins.all (
    v: builtins.isString v && builtins.stringLength v > 0
  ) registryValues) "all env var names must be non-empty strings";

  test_all_values_match_envvar_pattern = assert' (builtins.all (
    v: envVarPattern v != null
  ) registryValues) "all env var values must match uppercase env var pattern";

  # === No duplicate env var values ===

  test_no_duplicate_env_var_values = assert' (
    builtins.length uniqueValues == builtins.length registryValues
  ) "env var values must be unique across all providers";

  # === Cross-check: litellm-config.yml env refs vs registry ===

  test_litellm_config_env_refs_in_registry = assert' (builtins.all (
    ref: builtins.elem ref registryValues
  ) envRefs) "all os.environ/ vars in litellm-config.yml must be present in key-registry";
}
