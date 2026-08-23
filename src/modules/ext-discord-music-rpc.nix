# Discord Rich Presence for music (Spotify, Last.fm, Plex).
# launchd on macOS, systemd user service on NixOS.
args@{
  config,
  lib,
  pkgs,
  managedUsername ? null,
  username ? null,
  ...
}:
let
  effectiveUsername =
    if managedUsername != null then
      managedUsername
    else if username != null then
      username
    else
      config.home.username;

  repoRoot = builtins.getEnv "NUCLEUS_REPO_ROOT";

  overlay = (import ./lib/users-overlay.nix).mkUserOverlay {
    inherit effectiveUsername repoRoot;
  };

  discordMusicRpcConfigFile = overlay.selectFile "discord-music-rpc" "config.yaml";

  # Per-user service enable flag from src/users/ services.json (default: enabled).
  services = args.users.${config.home.username}.services or { };
  userEnable = services."discord-music-rpc".enable or true;

  pypresence = pkgs.python3Packages.buildPythonPackage rec {
    pname = "pypresence";
    version = "e941a582";

    src = pkgs.fetchFromGitHub {
      owner = "polyipseity";
      repo = "ext.pypresence";
      rev = "e941a582d0aa920d5e51301fbc9744d6ab4a9603";
      hash = "sha256-fHTAJWW2k9Tmtc5u8zWKf5ydaAPzAQYDCvi6X6UGcIQ=";
    };

    format = "pyproject";
    nativeBuildInputs = with pkgs.python3Packages; [
      setuptools
      wheel
    ];
    doCheck = false;
  };

  discord-music-rpc = pkgs.python3Packages.buildPythonApplication rec {
    pname = "discord-music-rpc";
    version = "0.1.3";

    src = pkgs.fetchFromGitHub {
      owner = "polyipseity";
      repo = "ext.discord-music-rpc";
      rev = "bba71027a684db53f3fcde5adbd3d42627241a83";
      hash = "sha256-JfXCCrlb6kfEgjQ22YaOYaevnyb6PCpFHcF3NEp30mg=";
    };

    format = "pyproject";

    nativeBuildInputs = with pkgs.python3Packages; [ hatchling ];

    propagatedBuildInputs = with pkgs.python3Packages; [
      pillow
      plexapi
      pydantic
      pypresence
      pystray
      pyyaml
      requests
      rich
      soundcloud-v2
      spotipy
      websockets
    ];

    # Remove the git dependency from pyproject.toml so pip does not attempt to
    # clone the repository at build time.  pypresence is provided via
    # propagatedBuildInputs above.
    postPatch = ''
      substituteInPlace pyproject.toml \
        --replace 'pypresence @ git+https://github.com/f0e/pypresence.git@66f43b724c8b9df9a34c96c90cee113b23d5a301' \
                  'pypresence'
    '';

    doCheck = false;
  };
in
{
  config = lib.mkMerge [
    {
      home.packages = [ discord-music-rpc ];

      # The app only writes the config file when the schema needs migration
      # (diff-driven, stat-cached) and tolerates read-only targets, so a
      # writable symlink is safe: repo-managed settings are preserved.
      # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
      home.file.".config/discord-music-rpc/config.yaml".source =
        config.lib.file.mkOutOfStoreSymlink discordMusicRpcConfigFile;
    }

    # macOS: launchd agent keeps the tray app running persistently after login.
    # This module is imported into the Home Manager config (home-manager.users),
    # so use HM-native launchd.agents with domain = "user" (installs to
    # ~/Library/LaunchAgents) rather than environment.userLaunchAgents, which is
    # a nix-darwin top-level option and does not exist in the HM context.
    (lib.mkIf (pkgs.stdenv.hostPlatform.isDarwin && userEnable) {
      launchd.agents."discord-music-rpc" = {
        domain = "user";
        config = {
          Label = "local.discord-music-rpc";
          ProgramArguments = [ "${discord-music-rpc}/bin/discord-music-rpc" ];
          KeepAlive = true;
          RunAtLoad = true;
          StandardOutPath = "${config.nucleus.logging.logDir}/discord-music-rpc/stdout.log";
          StandardErrorPath = "${config.nucleus.logging.logDir}/discord-music-rpc/stderr.log";
        };
      };
    })

    # NixOS: systemd user service for headless operation.
    (lib.mkIf (pkgs.stdenv.hostPlatform.isLinux && userEnable) {
      systemd.user.services."discord-music-rpc" = {
        Unit = {
          Description = "discord-music-rpc music presence for Discord";
          After = [ "network-online.target" ];
          Wants = [ "network-online.target" ];
        };
        Service = {
          Type = "simple";
          ExecStart = "${discord-music-rpc}/bin/discord-music-rpc";
          Restart = "always";
        };
        Install = {
          WantedBy = [ "default.target" ];
        };
      };
    })
  ];
}
