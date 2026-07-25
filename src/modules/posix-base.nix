# Shared system-layer defaults for POSIX hosts.
{
  config,
  lib,
  options,
  ...
}:
let
  hasLaunchdDaemonsOption = options ? launchd && options.launchd ? daemons;
in
{
  options.modules.gc = {
    expiry = lib.mkOption {
      type = lib.types.str;
      default = "7d";
      description = "Master expiry override. Per-tool options win.";
    };
    nixStoreExpiry = lib.mkOption {
      type = lib.types.str;
      default = config.modules.gc.expiry;
      defaultText = lib.literalExpression "config.modules.gc.expiry";
      description = "Duration for nix-collect-garbage --delete-older-than. Defaults to the master expiry value.";
    };
  };

  config = lib.mkMerge [
    {
      nix.settings = {
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
      };

      # Enforce baseline Git behavior globally for every local account.
      # Commit/tag signing is required by default, symlinks are enabled, and
      # POSIX hosts keep core.autocrlf=false so Git never rejects an invalid
      # boolean value and newline policy remains controlled by .gitattributes.
      programs.zsh.enable = true;
    }

    (lib.optionalAttrs (!hasLaunchdDaemonsOption) {
      # /etc/gitconfig is a writable symlink to the repo tree so local Git defaults
      # can be adjusted in-place without rebuild. Activation script creates the
      # Method 1 (writable symlink): symlink; runs as root via nucleus-apply.
      system.activationScripts.gitconfig = lib.mkAfter ''
        # Method 1 (writable symlink): repo changes take effect without rebuild.
        ln -sf "${builtins.getEnv "NUCLEUS_REPO_ROOT"}/src/modules/configs/git/system.gitconfig" /etc/gitconfig
      '';
    })
    (lib.optionalAttrs hasLaunchdDaemonsOption {
      system.activationScripts.gitconfig.text = ''
        # Method 1 (writable symlink): repo changes take effect without rebuild.
        ln -sf "${builtins.getEnv "NUCLEUS_REPO_ROOT"}/src/modules/configs/git/system.gitconfig" /etc/gitconfig
      '';
    })

    (lib.optionalAttrs (!hasLaunchdDaemonsOption) {
      nix.gc = {
        automatic = true;
        # Run store collection at local noon every day.
        dates = "12:00";
        options = "--delete-older-than ${config.modules.gc.nixStoreExpiry}";
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
    })
  ];
}
