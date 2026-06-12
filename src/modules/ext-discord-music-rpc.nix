# modules/ext-discord-music-rpc.nix — Music presence for Discord.
#
# discord-music-rpc shows your currently playing music in Discord via Rich
# Presence. Sources: Spotify, Last.fm, Plex, SoundCloud, YouTube.
#
# Package: built from the forked repo (forks/polyipseity branch) with pinned
# pypresence dependency fetched from git instead of resolved by pip.
# Config: out-of-store symlink to the tracked file in the live repo checkout
# so edits take effect without a rebuild.  Assumes the repo is at
# ~/dev/nucleus.
# Services: launchd on macOS, systemd user service on NixOS.
args@{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Per-user service enable flag from users.json (default: enabled).
  services = args.users.${config.home.username}.services or { };
  userEnable = services."discord-music-rpc".enable or true;
  # The canonical live checkout path is ~/dev/nucleus.  Use an out-of-store
  # symlink so config edits are picked up instantly from the mutable working
  # tree instead of requiring a Nix rebuild.
  liveConfigFile = "${config.home.homeDirectory}/dev/nucleus/src/modules/configs/discord-music-rpc/config.yaml";

  pypresence = pkgs.python3Packages.buildPythonPackage rec {
    pname = "pypresence";
    version = "66f43b72";

    src = pkgs.fetchFromGitHub {
      owner = "f0e";
      repo = "pypresence";
      rev = "66f43b724c8b9df9a34c96c90cee113b23d5a301";
      hash = "sha256-SbX+mNsiXlEiefLgBwaW9sIvFLfPJw7fZdwIpW6CD1Y=";
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
      rev = "ffe210a8b4e21735a9966174f50dfde145ab5f53";
      hash = "sha256-ahk3SWQkGybsfpzAUru4IUzdBI6Oy88eF7YOuixW9Xc=";
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

      # Out-of-store symlink to the live repo file — edit config.yaml in the
      # working tree and the running app sees the change immediately.  The
      # symlink target is resolved at activation time, not at build time.
      home.file.".config/discord-music-rpc/config.yaml".source =
        config.lib.file.mkOutOfStoreSymlink liveConfigFile;
    }

    # macOS: launchd agent keeps the tray app running persistently after login.
    (lib.mkIf (pkgs.stdenv.isDarwin && userEnable) {
      launchd.agents."discord-music-rpc" = {
        enable = true;
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
    (lib.mkIf (pkgs.stdenv.isLinux && userEnable) {
      systemd.user.services."discord-music-rpc" = {
        Unit = {
          Description = "discord-music-rpc music presence for Discord";
          After = [ "network-online.target" ];
          Wants = [ "network-online.target" ];
        };
        Service = {
          Type = "simple";
          ExecStart = "${discord-music-rpc}/bin/discord-music-rpc";
          Restart = "on-failure";
        };
        Install = {
          WantedBy = [ "default.target" ];
        };
      };
    })
  ];
}
