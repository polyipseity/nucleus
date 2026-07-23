# NixOS/jellyfin.nix — Host-level singleton Jellyfin service + HTTPS ingress.
#
# Jellyfin must run once per host (shared across all users). Running it as a
# system service avoids one-instance-per-Home-Manager-user fanout.
#
# HTTPS provided by nucleus.httpsProxy via the NixOS/https-proxy.nix mapping.
#
# Sources:
# - https://jellyfin.org/docs/general/post-install/networking/reverse-proxy/
{ lib, pkgs, ... }:
let
  jellyfinHttpPort = 8096;
in
{
  services.jellyfin = {
    enable = true;
    # Keep direct HTTP port off the host firewall; HTTPS is provided by Caddy.
    openFirewall = false;
  };

  nucleus.httpsProxy.virtualHosts.jellyfin = {
    listenPort = 8920;
    upstreamPort = jellyfinHttpPort;
  };

  # Activation script: converge Jellyfin accounts and libraries after the
  # Jellyfin service is running.  Mirrors the Darwin postActivation fragment but
  # uses a named script (nixos-specific option).
  #
  # Runs via a bundled script tree so the script can resolve its lib/
  # dependencies at runtime via SCRIPT_DIR.
  system.activationScripts.jellyfin-sync = lib.mkAfter (
    let
      # Bundle the script + lib dependencies so SCRIPT_DIR-relative sourcing works.
      scriptsBundle = pkgs.runCommand "nucleus-jellyfin-scripts" { preferLocalBuild = true; } ''
        mkdir -p "$out/services" "$out/lib"
        cp ${../../scripts/services/jellyfin-sync.sh} "$out/services/jellyfin-sync.sh"
        cp ${../../scripts/lib/lib.sh} "$out/lib/lib.sh"
        chmod +x "$out/services/jellyfin-sync.sh"
      '';
    in
    ''
      export NUCLEUS_REPO_ROOT="${lib.escapeShellArg (builtins.getEnv "NUCLEUS_REPO_ROOT")}"
      export PATH="${pkgs.jq}/bin:${pkgs.sops}/bin:$PATH"
      ${scriptsBundle}/services/jellyfin-sync.sh
    ''
  );
}
