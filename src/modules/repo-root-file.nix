# Materialize the nucleus repo root at /etc/nucleus/repo-root for all-process
# availability (POSIX parity with Windows Machine-scope NUCLEUS_REPO_ROOT).
{ lib, ... }:
let
  repoRoot = builtins.getEnv "NUCLEUS_REPO_ROOT";
in
{
  environment.etc."nucleus/repo-root" = lib.mkIf (repoRoot != "") {
    text = repoRoot + "\n";
    mode = "0444";
  };
}
