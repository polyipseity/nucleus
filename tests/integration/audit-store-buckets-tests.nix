# tests/integration/audit-store-buckets-tests.nix — GC root bucketing assertions.

let
  inherit (import ../lib.nix) containsRegex;

  auditLibText = builtins.readFile ../../src/scripts/lib/audit-store.sh;
in

assert containsRegex "_audit_store_gc_root_bucket" auditLibText;
assert containsRegex "gc roots by category" auditLibText;
assert containsRegex "direnv:" auditLibText;
assert containsRegex "home-manager:" auditLibText;

{
  success = true;
  message = "Audit GC root bucketing assertions passed";
}
