# tests/lib.nix: Shared test helpers for Nix tests.

rec {
  # Simple assertion helper with descriptive errors.
  assert' = cond: msg: if !cond then builtins.throw "ASSERTION FAILED: ${msg}" else null;

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
