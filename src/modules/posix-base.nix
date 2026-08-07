# Shared system-layer defaults for POSIX hosts.
{
  config,
  hostName,
  lib,
  options,
  pkgs,
  ...
}:
let
  hasLaunchdDaemonsOption = options ? launchd && options.launchd ? daemons;
  repoRoot = builtins.getEnv "NUCLEUS_REPO_ROOT";

  nixStoreSettings = {
    # Opportunistically deduplicate equal store paths via hard-linking to
    # reduce steady-state disk usage on both hosts.
    auto-optimise-store = true;
    # Keep flakes and modern nix CLI enabled consistently on both hosts.
    experimental-features = [
      "flakes"
      "nix-command"
    ];
    # nix-community cachix broadens binary cache coverage, especially for
    # aarch64-darwin where cache.nixos.org often lags.
    extra-substituters = [ "https://nix-community.cachix.org" ];
    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
    # Preserve derivation/output metadata for active shells and rollback
    # workflows so GC does not prune still-useful build context.
    keep-derivations = true;
    keep-outputs = true;
    lazy-trees = true;
    eval-cores = 0;
    # GC pressure thresholds (512 GB–first sizing; shared across hosts).
    min-free = 40 * 1024 * 1024 * 1024;
    max-free = 96 * 1024 * 1024 * 1024;
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
  imports = [ ./lib/gc-options.nix ];

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
        automatic = true;
        # Run store collection at local noon every day.
        dates = "12:00";
        options = "--delete-older-than ${config.modules.gc.nixStoreExpiry}";
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
        logGcSystem = pkgs.writeNucleusShellApplication {
          name = "log-gc-system";
          bundleDefault = true;
          runtimeInputs = [ pkgs.jq ];
          scriptName = "src/scripts/services/log-gc-system";
        };
      in
      {
        # Determinate Nix keeps nix-darwin `nix.enable = false`, so use launchd
        # daemons for equivalent NixOS systemd timer behavior on macOS.
        launchd.daemons.nixStoreGc = {
          serviceConfig = {
            ProgramArguments = [
              "/run/current-system/sw/bin/nix-collect-garbage"
              "--delete-older-than"
              "${config.modules.gc.nixStoreExpiry}"
            ];
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
              NUCLEUS_REPO_ROOT = repoRoot;
            };
            RunAtLoad = false;
            StartCalendarInterval = [
              {
                Hour = 12;
                Minute = 0;
              }
            ];
          };
        };
      }
    ))
  ];
}
