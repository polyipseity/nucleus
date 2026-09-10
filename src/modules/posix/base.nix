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
    # Opportunistically deduplicate equal store paths via hard-linking to
    # reduce steady-state disk usage on both hosts.
    auto-optimise-store = true;
    # Keep flakes and modern nix CLI enabled consistently on both hosts.
    experimental-features = [
      "flakes"
      "nix-command"
    ];
    # Substituter settings are managed in nix.custom.conf (method 2 read-only)
    # because nix.enable = false under Determinate Nix on macOS — nix-darwin's
    # nix.settings has no effect on substituters in that configuration.
    # Preserve derivation/output metadata for active shells and rollback
    # workflows so GC does not prune still-useful build context.
    keep-derivations = true;
    keep-outputs = true;
    lazy-trees = true;
    eval-cores = 0;
    # GC pressure thresholds (shared across hosts). min-free matches the
    # health-check free-space limit (scripts/health-check.{sh,ps1}
    # min_free_bytes) so the daemon starts reclaiming at the same point
    # pre-flight would block; max-free is 4x headroom in the same unit.
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
      # /etc/gitconfig is a writable symlink to the per-host gitconfig in the repo
      # tree so local Git defaults can be adjusted in-place without rebuild. A
      # same-folder .bak preserves any system-owned original the first time a real
      # file is replaced. Activation script creates the
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

        # Daily system log rotation — rotates root-owned system log files that
        # user-context gc cannot write. Cross-host parity with NixOS systemd
        # timer and Windows scheduled task.
        launchd.daemons."log-gc-system" = {
          serviceConfig = {
            Label = "local.log-gc-system";
            ProgramArguments = [
              "/bin/sh"
              "-c"
              "exec ${logGcSystem}/bin/nucleus-log-gc-system"
            ];
            EnvironmentVariables = {
              NUCLEUS_GC_EXPIRY = config.modules.gc.expiry;
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
