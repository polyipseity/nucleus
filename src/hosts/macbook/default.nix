# macbook/default.nix — nix-darwin entrypoint for the MacBook host.
# Aggregates all host-specific module fragments; no settings live here directly.
{ ... }:
{
  # Inject the host manual path into Home Manager at the user layer so the
  # system entrypoint never needs to define a Home Manager-only option.
  home-manager.sharedModules = [
    {
      nucleus.hostManualFile = "src/hosts/macbook/MANUAL.md";
      # MiddleClick: auto-start the menu bar gesture helper at login.
      # WHY LaunchAgent: MiddleClick is a background helper that must run in the
      # user session; RunAtLoad ensures it starts on every login without relying
      # on the macOS Login Items UI.
      launchd.agents."art.ginzburg.MiddleClick" = {
        enable = true;
        config = {
          Label = "art.ginzburg.MiddleClick";
          ProgramArguments = [ "/Applications/MiddleClick.app/Contents/MacOS/MiddleClick" ];
          RunAtLoad = true;
          KeepAlive = false;
        };
      };
    }
  ];

  imports = [
    ../../modules/core.nix
    ../../modules/gnupg.nix
    ../../modules/posix-base.nix
    ../../modules/posix-security.nix
    ../../modules/posix-sops.nix
    ../../modules/posix-user-shell.nix
    ./activation.nix
    ./base.nix
    ./defaults.nix
    ./homebrew.nix
    ./manual-installations.nix
    ./networking.nix
    ./security.nix
    ./sops.nix
  ];
}
