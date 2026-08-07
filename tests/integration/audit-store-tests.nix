# tests/integration/audit-store-tests.nix — Content assertions for store audit helpers.

let
  inherit (import ../lib.nix) containsRegex;

  auditLibText = builtins.readFile ../../src/scripts/lib/audit-store.sh;
  auditCliText = builtins.readFile ../../scripts/audit-store.sh;
  healthCheckText = builtins.readFile ../../scripts/health-check.sh;
  instructionsText = builtins.readFile ../../.agents/instructions/nix-store-space.instructions.md;
in

assert containsRegex "audit_nix_store_closures" auditLibText;
assert containsRegex "nix path-info --json-format 1 --json --all --closure-size" auditLibText;
assert containsRegex "def hsize:" auditLibText;
assert containsRegex "audit_store_acquire_privileges" auditLibText;
assert containsRegex "_audit_store_run_privileged" auditLibText;
assert containsRegex "launchctl kickstart -k system/" auditLibText;
assert containsRegex "_audit_store_top_closures_jq 15" auditLibText;
assert containsRegex "linux-builder guest: nix not in PATH" auditLibText;
assert containsRegex "extra-experimental-features nix-command" auditLibText;
assert containsRegex "linux-builder ssh attempt" auditLibText;
assert containsRegex "audit_nix_generations" auditLibText;
assert containsRegex "audit_nix_gc_roots" auditLibText;
assert containsRegex "_audit_store_gc_root_bucket" auditLibText;
assert containsRegex "gc roots by category" auditLibText;
assert containsRegex "audit_nix_generation_reclaim_hint" auditLibText;
assert containsRegex "generation reclaim hint" auditLibText;
assert containsRegex "reclaimable via nucleus-gc" auditLibText;
assert containsRegex "_audit_store_closure_groups_jq" auditLibText;
assert containsRegex "grouped by path prefix" auditLibText;
assert containsRegex "nix-store --gc --print-roots" auditLibText;
assert containsRegex "audit_stale_result_symlinks" auditLibText;
assert containsRegex "audit_linux_builder_store" auditLibText;
assert containsRegex "audit_store_report" auditLibText;
assert containsRegex "audit-store.sh" auditCliText;
assert containsRegex "audit-store.sh" instructionsText;
assert containsRegex "audit-store.sh" healthCheckText;
assert containsRegex "audit_store_report" healthCheckText;
assert containsRegex "store_audit=false" healthCheckText;
assert containsRegex "--store-audit" healthCheckText;
assert containsRegex "NUCLEUS_HEALTH_CHECK_STORE_AUDIT" healthCheckText;

{
  success = true;
  message = "Store audit helper content assertions passed";
}
