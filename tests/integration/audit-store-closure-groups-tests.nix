# tests/integration/audit-store-closure-groups-tests.nix — Grouped closure assertions.

let
  inherit (import ../lib.nix) containsRegex;

  auditLibText = builtins.readFile ../../src/scripts/lib/audit-store.sh;
in

assert containsRegex "_audit_store_closure_groups_jq" auditLibText;
assert containsRegex "grouped by path prefix" auditLibText;
assert containsRegex "darwin-system" auditLibText;
assert containsRegex "home-manager-generation" auditLibText;

{
  success = true;
  message = "Audit grouped closure assertions passed";
}
