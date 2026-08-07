# tests/integration/audit-store-reclaim-hints-tests.nix — Generation reclaim hint assertions.

let
  inherit (import ../lib.nix) containsRegex;

  auditLibText = builtins.readFile ../../src/scripts/lib/audit-store.sh;
in

assert containsRegex "audit_nix_generation_reclaim_hint" auditLibText;
assert containsRegex "_audit_store_age_cutoff_epoch" auditLibText;
assert containsRegex "reclaimable via nucleus-gc" auditLibText;
assert containsRegex "intersection" auditLibText;

{
  success = true;
  message = "Audit generation reclaim hint assertions passed";
}
