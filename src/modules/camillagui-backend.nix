# modules/camillagui-backend.nix — CamillaDSP web GUI config.
#
# Cross-platform shared module. Defines the HTTPS proxy virtual host here;
# user-level config deployment happens via Home Manager in modules/home.nix.
# Service-manager-specific definitions live in src/hosts/{MacBook,NixOS}/.
{
  config =
    let
      servicesJSON = builtins.fromJSON (builtins.readFile ./services.json);
    in
    {
      nucleus.httpsProxy.virtualHosts.camillagui = {
        listenPort = servicesJSON.camillagui-backend.network.https.port;
        upstreamPort = servicesJSON.camillagui-backend.network.default.port;
      };
    };
}
