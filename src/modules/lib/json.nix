# src/modules/lib/json.nix — deterministic JSON serialization helpers.
#
# Generated JSON artifacts committed to the repo (e.g. winget-packages.json) must
# be byte-stable across runs so diffs show only real changes. Nix's
# builtins.toJSON preserves attrset insertion order and does not sort keys, so
# callers that need sorted output must build the value in sorted order. These
# helpers emit a multi-line, 2-space-indented JSON string with sorted
# array elements (for set/allow-list arrays), and a single trailing newline.
# Empty objects/arrays stay compact ("{}" / "[]").

{ ... }:

let
  # Case-sensitive ascending sort (Nix '<' on strings compares by char code:
  # uppercase A-Z precede lowercase a-z).
  caseSort = builtins.sort (a: b: a < b);

  # Two-space indent for a given nesting level.
  indent = level: builtins.concatStringsSep "" (builtins.genList (_: "  ") level);

  # Serialize a value to a multi-line, 2-space-indented JSON string with sorted
  # keys and sorted arrays. Objects: keys emitted in case-sensitive ascending
  # order, one per line. Arrays: elements sorted case-sensitively when every
  # element is a string (set/allow-list shape); otherwise left in order, one per
  # line. Scalars: delegated to builtins.toJSON. Empty attrs/lists stay compact.
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
  # Build a deterministic JSON document: multi-line, 2-space-indented, sorted
  # keys, sorted string arrays, and a single trailing newline. Input is any Nix
  # value (attrs, lists, scalars).
  toSortedJSON = value: (toSortedJSONValue 0 value) + "\n";
}
