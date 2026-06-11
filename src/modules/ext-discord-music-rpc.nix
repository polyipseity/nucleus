# modules/ext-discord-music-rpc.nix — Music presence for Discord.
#
# discord-music-rpc shows your currently playing music in Discord via Rich
# Presence. Sources: Spotify, Last.fm, Plex, SoundCloud, YouTube.
#
# Package: built from the forked repo (forks/polyipseity branch) with pinned
# pypresence dependency fetched from git instead of resolved by pip.
# Config: symlinked from the Nix store with all default values written
# explicitly so the file serves as both configuration and documentation.
# Services: launchd on macOS, systemd user service on NixOS.
{
  config,
  lib,
  pkgs,
  ...
}:
let
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

      # Symlinked from the Nix store.  All default values are written
      # explicitly so the file serves as both configuration and documentation.
      xdg.configFile."discord-music-rpc/config.yaml".text = ''
        discord:
          status_type: artist
          show_progress: true
          show_source_logo: true
          show_urls: true
          show_ad: true
        spotify:
          enabled: false
          client_id: null
          client_secret: null
          redirect_uri: http://localhost:8888/callback
        lastfm:
          enabled: false
          username: null
          api_key: null
        plex:
          enabled: false
          server_url: null
          token: null
          libraries: []
        soundcloud:
          enabled: false
        youtube:
          enabled: false
      '';
    }

    # macOS: launchd agent keeps the tray app running persistently after login.
    (lib.mkIf pkgs.stdenv.isDarwin {
      launchd.agents."discord-music-rpc" = {
        enable = true;
        config = {
          Label = "local.discord-music-rpc";
          ProgramArguments = [ "${discord-music-rpc}/bin/discord-music-rpc" ];
          KeepAlive = true;
          RunAtLoad = true;
          StandardOutPath = "/dev/null";
          StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/discord-music-rpc/main.log";
        };
      };
    })

    # NixOS: systemd user service for headless operation.
    (lib.mkIf pkgs.stdenv.isLinux {
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
