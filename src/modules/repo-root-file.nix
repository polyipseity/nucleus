# Materialize the nucleus repo root at the SYSTEM root for all-process
# availability (POSIX parity with Windows Machine-scope NUCLEUS_REPO_ROOT).
#
# environment.etc always nests under /etc, so we write the file directly to the
# absolute SYSTEM root via a system activation script instead.
{ lib, pkgs, ... }:
let
  repoRoot = builtins.getEnv "NUCLEUS_REPO_ROOT";
  repoRootPath =
    if pkgs.stdenv.hostPlatform.isDarwin then
      "/Library/Application Support/nucleus/repo-root"
    else
      "/var/lib/nucleus/repo-root";
in
{
  system.activationScripts.materialize-repo-root.text = lib.mkIf (repoRoot != "") ''
    install -d -m 0755 "$(dirname "${repoRootPath}")"
    printf '%s\n' "${repoRoot}" > "${repoRootPath}"
  '';
}
