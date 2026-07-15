# tests/lib.nix — Shared test helpers for Nix tests.

rec {
  # Simple assertion helper with descriptive errors.
  assert' = cond: msg: if !cond then builtins.throw "ASSERTION FAILED: ${msg}" else null;

  # Flatten by replacing newlines with spaces.
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;
  # Regex-like match via builtins.match with .* prefix/suffix.
  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;
}
