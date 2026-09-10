# Shared SOPS YAML key-parsing utilities for eval-time validation.
# Used by env-secrets-sops.nix and hermes-agent.nix to assert that
# declared sops.secrets key names exist in the referenced SOPS files
# before build time.
#
# Key names are plaintext in SOPS YAML (only values are encrypted),
# so we can parse them at eval time.
{
  # Parse top-level key names from a SOPS YAML file.
  # Returns a list of attribute names (key strings).
  parseSopsKeys =
    file:
    let
      content = builtins.readFile file;
      lines = builtins.split "\n" content;
      nonEmpty = builtins.filter (l: builtins.isString l && l != "") lines;
      # Extract key name: text before first `:`, trimmed.
      extractKey =
        line:
        let
          parts = builtins.split ":" line;
          key = builtins.head parts;
        in
        let
          trimmed = builtins.replaceStrings [ " " "\t" ] [ "" "" ] key;
        in
        if builtins.stringLength trimmed > 0 && !(builtins.match "#.*" trimmed != null) then
          trimmed
        else
          null;
      keys = builtins.filter (k: k != null) (map extractKey nonEmpty);
    in
    builtins.attrNames (
      builtins.listToAttrs (
        map (k: {
          name = k;
          value = true;
        }) keys
      )
    );

  # Find declared secret names missing from a SOPS file's parsed keys.
  # `sopsKeys`: result of parseSopsKeys (list of key name strings).
  # `entries`: list of attrsets with `.name` field.
  # Returns: list of missing key name strings.
  missingSopsKeys =
    sopsKeys: entries:
    let
      declaredNames = map (e: e.name) entries;
    in
    builtins.filter (name: !(builtins.elem name sopsKeys)) declaredNames;
}
