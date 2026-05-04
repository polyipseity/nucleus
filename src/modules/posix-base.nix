# modules/posix-base.nix — Shared system-layer defaults for POSIX hosts.
# Imported by both nix-darwin and NixOS host entrypoints.
{ lib, options, ... }:
let
  hasLaunchdDaemonsOption = options ? launchd && options.launchd ? daemons;
in
{
  config = lib.mkMerge [
    {
      nix.settings = {
        # Opportunistically deduplicate equal store paths via hard-linking to
        # reduce steady-state disk usage on both hosts.
        auto-optimise-store = true;
        # Keep flakes and modern nix CLI enabled consistently on both hosts.
        experimental-features = [ "flakes" "nix-command" ];
        # Preserve derivation/output metadata for active shells and rollback
        # workflows so GC does not prune still-useful build context.
        keep-derivations = true;
        keep-outputs = true;
      };

      # Enforce baseline Git behavior globally for every local account.
      # Commit/tag signing is required by default, symlinks are enabled, and
      # line-ending handling follows core.autocrlf=auto for cross-platform repos.
      environment.etc."gitconfig".text = ''
        [commit]
          gpgsign = true
        [core]
          autocrlf = auto
          symlinks = true
        [tag]
          gpgsign = true
      '';

      # Ensure zsh is available as a valid login shell system-wide.
      programs.zsh.enable = true;
    }

    (lib.optionalAttrs (!hasLaunchdDaemonsOption) {
      nix.gc = {
        automatic = true;
        # Run store collection at local midnight every day.
        interval = "00:00";
        # Keep rollback headroom for one month while capping long-term store
        # growth from iterative host/application rebuilds.
        options = "--delete-older-than 30d";
      };
    })

    (lib.optionalAttrs hasLaunchdDaemonsOption {
      # Determinate Nix keeps nix-darwin `nix.enable = false`, so use a launchd
      # daemon for equivalent daily store collection behavior on macOS.
      launchd.daemons.nixStoreGc = {
        serviceConfig = {
          ProgramArguments = [
            "/run/current-system/sw/bin/nix-collect-garbage"
            "--delete-older-than"
            "30d"
          ];
          StartCalendarInterval = [
            {
              Hour = 0;
              Minute = 0;
            }
          ];
        };
      };
    })
  ];
}
