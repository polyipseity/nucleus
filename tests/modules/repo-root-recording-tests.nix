let
  inherit (import ../lib.nix) containsRegex;

  applyText = builtins.readFile ../../src/scripts/apply.sh;
  libText = builtins.readFile ../../src/scripts/lib/lib.sh;
in
# The live repo root is recorded by scripts/apply.sh on both POSIX hosts; the
# Nix evaluation-time path is a read-only store snapshot and must never be
# materialized as the repo root.
assert !(builtins.pathExists ../../src/modules/posix/repo-root-file.nix);
assert containsRegex "/Library/Application Support/nucleus/repo-root" applyText;
assert containsRegex "/var/lib/nucleus/repo-root" applyText;
assert containsRegex "derive_repo_root" applyText;
assert !containsRegex "nucleus-repo-root" applyText;
# Store snapshots are rejected at every resolution source (env var and system file).
assert !containsRegex "nucleus-repo-root" libText;
assert containsRegex "Nix store path" libText;
{
  success = true;
  message = "repo-root recording tests passed";
}
