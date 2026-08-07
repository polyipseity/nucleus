# tests/integration/audit-store-tests.nix — Content assertions for store audit helpers.

let
  inherit (import ../lib.nix) containsRegex;

  auditLibText = builtins.readFile ../../src/scripts/lib/audit-store.sh;
  auditCliText = builtins.readFile ../../scripts/audit-store.sh;
  healthCheckText = builtins.readFile ../../scripts/health-check.sh;
  instructionsText = builtins.readFile ../../.agents/instructions/nix-store-space.instructions.md;
in

assert containsRegex "audit_nix_store_closures" auditLibText;
assert containsRegex "nix path-info --json --all --closure-size" auditLibText;
assert containsRegex "def hsize:" auditLibText;
assert containsRegex "_audit_store_run_privileged" auditLibText;
assert containsRegex "launchctl kickstart -k system/" auditLibText;
assert containsRegex "linux-builder ssh attempt" auditLibText;
assert containsRegex "audit_nix_generations" auditLibText;
assert containsRegex "audit_nix_gc_roots" auditLibText;
assert containsRegex "nix-store --print-roots failed" auditLibText;
assert containsRegex "audit_stale_result_symlinks" auditLibText;
assert containsRegex "audit_linux_builder_store" auditLibText;
assert containsRegex "audit_store_report" auditLibText;
assert containsRegex "audit-store.sh" auditCliText;
assert containsRegex "audit-store.sh" instructionsText;
assert containsRegex "audit-store.sh" healthCheckText;
assert containsRegex "audit_store_report" healthCheckText;
assert containsRegex "--no-store-audit" healthCheckText;
assert containsRegex "NUCLEUS_HEALTH_CHECK_NO_STORE_AUDIT" healthCheckText;

{
  success = true;
  message = "Store audit helper content assertions passed";
}
