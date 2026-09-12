# tests/modules/nix-custom-conf-tests.nix — validates nix.custom.conf key format and uniqueness.
#
# Uses only builtins — no <nixpkgs> import, so nix-instantiate --eval works without network.
let
  assert' = cond: msg: if !cond then builtins.throw "ASSERTION FAILED: ${msg}" else null;

  confFile = builtins.readFile ../../src/modules/configs/nix/nix.custom.conf;

  # builtins.split returns mixed list of strings and lists (matched groups).
  # Flatten to get only strings.
  flattenSplit = xs: builtins.concatLists (map (x:
    if builtins.isList x then x else [x]
  ) xs);

  # Split a string by a delimiter character.
  splitStr = sep: s: flattenSplit (builtins.split sep s);

  # Find position of first ':' in a string
  findColon = s: pos:
    if pos >= builtins.stringLength s then -1
    else if builtins.substring pos 1 s == ":" then pos
    else findColon s (pos + 1);

  # Extract the extra-trusted-public-keys line
  allLines = splitStr "\n" confFile;
  matching = builtins.filter (l: builtins.substring 0 28 l == "extra-trusted-public-keys = ") allLines;
  keysLine =
    if matching == [ ] then
      builtins.throw "nix.custom.conf: no extra-trusted-public-keys line found"
    else
      builtins.substring 28 (-1) (builtins.head matching);

  keys = builtins.filter (k: k != "") (splitStr " " keysLine);
  totalKeys = builtins.length keys;

  # Validate each key: must be name:base64= format
  validateKey =
    key:
    let
      colonPos = findColon key 0;
      name = builtins.substring 0 colonPos key;
      rest = builtins.substring (colonPos + 1) (-1) key;
      hasEq = builtins.substring (builtins.stringLength rest - 1) 1 rest == "=";
      base64Part = builtins.substring 0 (builtins.stringLength rest - 1) rest;
    in
    name != "" && base64Part != "" && hasEq;

  invalidKeys = builtins.filter (k: !validateKey k) keys;

  # Unique filter
  uniqueList =
    list:
    let
      go =
        seen: remaining:
        if remaining == [ ] then [ ]
        else
          let h = builtins.head remaining; t = builtins.tail remaining;
          in if builtins.elem h seen then go seen t else [ h ] ++ go (seen ++ [ h ]) t;
    in
    go [ ] list;

  uniqueKeys = uniqueList keys;
  hasDuplicates = builtins.length keys != builtins.length uniqueKeys;

  # FlakeHub keys must follow cache.flakehub.com-N naming
  fhKeys = builtins.filter (k: builtins.substring 0 19 k == "cache.flakehub.com-") keys;
  invalidFhNames = builtins.filter (k:
    let name = builtins.substring 0 (findColon k 0) k;
    in builtins.match "cache\\.flakehub\\.com-[0-9]+" name == null
  ) fhKeys;

  # FlakeHub key IDs must be sequential starting from 3
  fhIds = map (k:
    let name = builtins.substring 0 (findColon k 0) k;
    in builtins.fromJSON (builtins.substring 19 (-1) name)
  ) fhKeys;
  sortedFhIds = builtins.sort (a: b: a < b) fhIds;
  expectedFhIds = builtins.genList (i: i + 3) (builtins.length fhIds);
  fhSequential = sortedFhIds == expectedFhIds;
in
# Force all validation via builtins.seq chain — each throws on failure.
# The result is used as the success field so Nix must evaluate it.
builtins.seq (assert' (totalKeys > 0) "nix.custom.conf: extra-trusted-public-keys is empty")
(builtins.seq (assert' (invalidKeys == [ ]) "nix.custom.conf: malformed key(s): ${builtins.concatStringsSep ", " invalidKeys}")
(builtins.seq (assert' (!hasDuplicates) "nix.custom.conf: duplicate keys detected")
(builtins.seq (assert' (invalidFhNames == [ ]) "nix.custom.conf: FlakeHub key names don't match cache.flakehub.com-N pattern")
(builtins.seq (assert' fhSequential "nix.custom.conf: FlakeHub key IDs are not sequential from 3")
{
  success = true;
  message = "nix.custom.conf: ${builtins.toString totalKeys} keys validated (format, uniqueness, FlakeHub naming)";
}))))
