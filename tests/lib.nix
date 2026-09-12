# tests/lib.nix — Shared test helpers for Nix tests.

rec {
  # Simple assertion helper with descriptive errors.
  assert' = cond: msg: if !cond then builtins.throw "ASSERTION FAILED: ${msg}" else null;

  # Flatten by replacing newlines with spaces.
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;
  # Regex-like match via builtins.match with .* prefix/suffix.
  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;
  # Pure substring search — no regex, avoids special-char issues.
  containsString = needle: haystack: let
    stripped = builtins.replaceStrings [ needle ] [ "" ] haystack;
  in stripped != haystack;

  # Tail-recursive list helpers.
  all =
    pred: list:
    if list == [ ] then
      true
    else if pred (builtins.head list) then
      all pred (builtins.tail list)
    else
      false;
  any =
    pred: list:
    if list == [ ] then
      false
    else if pred (builtins.head list) then
      true
    else
      any pred (builtins.tail list);
}
