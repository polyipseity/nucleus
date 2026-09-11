# hosts/NixOS/camillagui-backend.nix — CamillaDSP GUI systemd service.
#
# Runs as the primary user so the daemon can access user-level config at
# ~/.config/camillagui-backend/. Config is deployed by Home Manager in
# modules/home.nix.
{ pkgs, username, ... }:

{
  systemd.services.camillagui-backend = {
    description = "CamillaDSP web GUI";
    after = [
      "network-online.target"
      "camilladsp.service"
    ];
    wants = [
      "network-online.target"
      "camilladsp.service"
    ];
    # WHY the backend creates this itself: its own application log (log_file in
    # config-NixOS.yml) is written into camilladsp's log dir, and NixOS has no user-log-dir
    # provisioner — log-dirs-init.sh only creates user dirs on Darwin. The unit prepares
    # its own target rather than relying on another service's preStart.
    preStart = ''
      mkdir -p '%h/.local/share/nucleus/logs/camilladsp'
    '';
    serviceConfig = {
      Type = "simple";
      User = username;
      ExecStart = "${pkgs.camillagui-backend}/bin/camillagui-backend -c %h/.config/camillagui-backend/config.yml";
      Restart = "on-failure";
    };
    wantedBy = [ "default.target" ];
  };
}
