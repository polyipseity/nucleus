# src/modules/lib/json.nix — deterministic JSON serialization helpers.
#
# Generated JSON artifacts committed to the repo (e.g. winget-packages.json) must
# be byte-stable across runs so diffs show only real changes. Nix's
# builtins.toJSON preserves attrset insertion order and does not sort keys, so
# callers that need sorted output must build the value in sorted order. These
# helpers emit a JSON string with case-sensitively sorted object keys, sorted
# array elements (for set/allow-list arrays), and a single trailing newline.

{ ... }:

let
  # Case-sensitive ascending sort (Nix '<' on strings compares by char code:
  # uppercase A-Z precede lowercase a-z).
  caseSort = builtins.sort (a: b: a < b);

  # Serialize a value to a JSON string with sorted keys and sorted arrays.
  # Objects: keys emitted in case-sensitive ascending order. Arrays: elements
  # sorted case-sensitively when every element is a string (set/allow-list
  # shape); otherwise left in order. Scalars: delegated to builtins.toJSON.
  toSortedJSONValue =
    value:
    if builtins.isAttrs value then
      let
        keys = caseSort (builtins.attrNames value);
        body = builtins.concatStringsSep ", " (
          map (k: ''"${k}": ${toSortedJSONValue (builtins.getAttr k value)}'') keys
        );
      in
      "{ ${body} }"
    else if builtins.isList value then
      let
        allStrings = builtins.all builtins.isString value;
        elems = if allStrings then caseSort value else value;
        body = builtins.concatStringsSep ", " (map toSortedJSONValue elems);
      in
      "[ ${body} ]"
    else
      builtins.toJSON value;
in
{
  # Build a deterministic JSON document: sorted keys, sorted string arrays, and a
  # single trailing newline. Input is any Nix value (attrs, lists, scalars).
  toSortedJSON = value: (toSortedJSONValue value) + "\n";
}
