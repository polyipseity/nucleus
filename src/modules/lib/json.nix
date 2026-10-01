# src/modules/lib/json.nix - deterministic JSON serialization. Committed
# artifacts (e.g. winget-packages.json) must be byte-stable across runs so diffs
# show only real changes, and builtins.toJSON preserves insertion order without
# sorting keys, so these helpers do the sorting.

{ ... }:

let
  # Case-sensitive ascending sort: Nix '<' compares by char code, so uppercase
  # precedes lowercase.
  caseSort = builtins.sort (a: b: a < b);

  # Two-space indent per nesting level.
  indent = level: builtins.concatStringsSep "" (builtins.genList (_: "  ") level);

  # Sort arrays case-sensitively only when every element is a string (the
  # set/allow-list shape); otherwise leave the order alone.
  toSortedJSONValue =
    level: value:
    if builtins.isAttrs value then
      let
        keys = caseSort (builtins.attrNames value);
      in
      if keys == [ ] then
        "{}"
      else
        let
          body = builtins.concatStringsSep ",\n" (
            map (
              k: indent (level + 1) + ''"${k}": ${toSortedJSONValue (level + 1) (builtins.getAttr k value)}''
            ) keys
          );
        in
        "{\n" + body + "\n" + indent level + "}"
    else if builtins.isList value then
      if value == [ ] then
        "[]"
      else
        let
          allStrings = builtins.all builtins.isString value;
          elems = if allStrings then caseSort value else value;
          body = builtins.concatStringsSep ",\n" (
            map (e: indent (level + 1) + toSortedJSONValue (level + 1) e) elems
          );
        in
        "[\n" + body + "\n" + indent level + "]"
    else
      builtins.toJSON value;
in
{
  # Sorted keys, sorted string arrays, one trailing newline. Empty objects and
  # arrays stay compact.
  toSortedJSON = value: (toSortedJSONValue 0 value) + "\n";
}
