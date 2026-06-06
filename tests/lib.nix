# tests/lib.nix — Shared test helpers for tests/src/*.nix.

{
  # Simple assertion helper with descriptive errors.
  assert' = cond: msg: if !cond then builtins.throw "ASSERTION FAILED: ${msg}" else null;
}
