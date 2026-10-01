# Shared system-layer defaults for POSIX hosts.
{
  config,
  hostName,
  lib,
  options,
  pkgs,
  repoRoot,
  username,
  ...
}:
let
  hasLaunchdDaemonsOption = options ? launchd && options.launchd ? daemons;

  nixStoreSettings = {
    auto-optimise-store = true;
    experimental-features = [
      "flakes"
      "nix-command"
    ];
    # Substituters live in nix.custom.conf (method 2): nix.enable = false under
    # Determinate Nix on macOS, so nix.settings does not reach them there.
    # Both flags keep rollback and nix-shell working after GC.
    keep-derivations = true;
    keep-outputs = true;
    lazy-trees = true;
    eval-cores = 0;
    # min-free matches the health-check limit in scripts/health-check.{sh,ps1}
    # so the daemon starts reclaiming where pre-flight starts blocking.
    min-free = 16000000000; # 16 GB
    max-free = 64000000000; # 64 GB
  };

  gitconfigActivation = ''
    # check-suppress:config-method: method 1 (writable symlink) -- per-host file; repo changes take effect without rebuild.
    if [ -f /etc/gitconfig ] && [ ! -L /etc/gitconfig ] && [ ! -e /etc/gitconfig.bak ]; then
      mv /etc/gitconfig /etc/gitconfig.bak
    fi
    ln -sf "${repoRoot}/src/modules/configs/git/${hostName}.gitconfig" /etc/gitconfig
  '';
in
{
  imports = [ ../lib/gc-options.nix ];

  config = lib.mkMerge [
    {
      nix.settings = nixStoreSettings;
      programs.zsh.enable = true;
    }

    (lib.optionalAttrs (!hasLaunchdDaemonsOption) {
      # Writable symlink into the repo tree, with a same-folder .bak for any
      # system-owned original replaced the first time.
      # check-suppress:config-method: method 1 (writable symlink) -- symlink; runs as root via nucleus-apply.
      system.activationScripts.gitconfig = lib.mkAfter gitconfigActivation;

      nix.gc = {
        # Daily store GC is handled by nucleus-nix-store-gc (activation.nix timer).
        automatic = false;
      };

      nix.optimise = {
        automatic = true;
        dates = [ "03:45" ];
      };
    })

    (lib.optionalAttrs hasLaunchdDaemonsOption {
      system.activationScripts.gitconfig.text = gitconfigActivation;
    })

    (lib.optionalAttrs hasLaunchdDaemonsOption (
      let
        # Shared GC application derivations (plan item 6).
        gcApps = import ../gc-activations.nix { inherit pkgs; };
        inherit (gcApps) logGcSystem nixStoreGc gcWeekly;
      in
      {
        # Determinate Nix keeps nix-darwin `nix.enable = false`, so use launchd
        # daemons for equivalent NixOS systemd timer behavior on macOS.
        launchd.daemons.nixStoreGc = {
          serviceConfig = {
            ProgramArguments = [
              "/bin/sh"
              "-c"
              "exec ${nixStoreGc}/bin/nucleus-nix-store-gc"
            ];
            EnvironmentVariables = {
              NUCLEUS_GC_EXPIRY = config.modules.gc.expiry;
              NUCLEUS_GC_NIX_EXPIRY = config.modules.gc.nixStoreExpiry;
              NUCLEUS_GC_GENERATIONS_KEEP = toString config.modules.gc.generationsKeep;
              NUCLEUS_GC_SYSTEM_GENERATIONS_KEEP = toString config.modules.gc.systemGenerationsKeep;
            };
            StartCalendarInterval = [
              {
                Hour = 12;
                Minute = 0;
              }
            ];
          };
        };

        launchd.daemons.nixStoreOptimise = {
          serviceConfig = {
            ProgramArguments = [
              "/run/current-system/sw/bin/nix-store"
              "--optimise"
            ];
            StartCalendarInterval = [
              {
                Weekday = 0;
                Hour = 3;
                Minute = 45;
              }
            ];
          };
        };

        # System logs are root-owned, so user-context gc cannot rotate them.
        # Parity with the NixOS systemd timer and the Windows scheduled task.
        launchd.daemons."log-gc-system" = {
          serviceConfig = {
            Label = "local.log-gc-system";
            ProgramArguments = [
              "/bin/sh"
              "-c"
              "exec ${logGcSystem}/bin/nucleus-log-gc-system"
            ];
            EnvironmentVariables = {
              NUCLEUS_LOG_EXPIRY = config.nucleus.logging.rotation.expiry;
            };
            RunAtLoad = false;
            # WHY: StartCalendarInterval is broken on this system — the
            # com.apple.launchd.calendarinterval event channel shows active=0
            # and all StartCalendarInterval daemons have runs=0. StartInterval
            # fires 24h after last run; less predictable but reliable.
            StartInterval = 86400;
          };
        };

        launchd.daemons.gc-weekly = {
          serviceConfig = {
            Label = "local.gc-weekly";
            ProgramArguments = [ "${gcWeekly}/bin/nucleus-gc-weekly" ];
            EnvironmentVariables = {
              NUCLEUS_GC_EXPIRY = config.modules.gc.expiry;
              NUCLEUS_LOG_EXPIRY = config.nucleus.logging.rotation.expiry;
              NUCLEUS_GC_GENERATIONS_KEEP = toString config.modules.gc.generationsKeep;
              NUCLEUS_USERNAME = username;
            };
            RunAtLoad = false;
            StartInterval = 86400;
          };
        };
      }
    ))
  ];
}
