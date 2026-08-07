# tests/integration/store-space-audit-tests.nix — Content assertions for store audit helpers.

let
  inherit (import ../lib.nix) containsRegex;

  auditLibText = builtins.readFile ../../src/scripts/lib/audit-store-space.sh;
  auditCliText = builtins.readFile ../../scripts/audit-store-space.sh;
  instructionsText = builtins.readFile ../../.agents/instructions/nix-store-space.instructions.md;
in

assert containsRegex "audit_nix_store_closures" auditLibText;
assert containsRegex "nix path-info --json --all --closure-size" auditLibText;
assert containsRegex "_audit_store_run_privileged" auditLibText;
assert containsRegex "launchctl kickstart -k system/" auditLibText;
assert containsRegex "linux-builder ssh attempt" auditLibText;
assert containsRegex "audit_nix_generations" auditLibText;
assert containsRegex "audit_nix_gc_roots" auditLibText;
assert containsRegex "nix-store --print-roots" auditLibText;
assert containsRegex "audit_stale_result_symlinks" auditLibText;
assert containsRegex "audit_linux_builder_store" auditLibText;
assert containsRegex "audit_store_space_report" auditLibText;
assert containsRegex "audit-store-space.sh" auditCliText;
assert containsRegex "audit-store-space.sh" instructionsText;

{
  success = true;
  message = "Store space audit helper content assertions passed";
}
