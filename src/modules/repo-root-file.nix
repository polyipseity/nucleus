# Materialize the nucleus repo root at the SYSTEM root for all-process
# availability (POSIX parity with Windows Machine-scope NUCLEUS_REPO_ROOT).
#
# environment.etc always nests under /etc, so we write the file directly to the
# absolute SYSTEM root via a system activation script instead.
{ pkgs, repoRoot, ... }:
let
  repoRootPath =
    if pkgs.stdenv.hostPlatform.isDarwin then
      "/Library/Application Support/nucleus/repo-root"
    else
      "/var/lib/nucleus/repo-root";
in
{
  system.activationScripts.materialize-repo-root.text = ''
    install -d -m 0755 "$(dirname "${repoRootPath}")"
    if [ -f "${repoRootPath}" ]; then
      _existing="$(cat "${repoRootPath}" 2>/dev/null || true)"  # check-suppress:suppression_doc: file may not exist on first activation; empty result falls through to Nix store path fallback
      case "$_existing" in
        /*) printf '%s\n' "$_existing" > "${repoRootPath}" ;;
        *) printf '%s\n' "${repoRoot}" > "${repoRootPath}" ;;
      esac
    else
      printf '%s\n' "${repoRoot}" > "${repoRootPath}"
    fi
  '';
}
