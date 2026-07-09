# Discord Rich Presence for music (Spotify, Last.fm, Plex).
# launchd on macOS, systemd user service on NixOS.
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
      rev = "9a44dcd0e912e42fe029eb319153a89029f8ab18";
      hash = "sha256-iLtXeDny+sbKY4PCO7zCp2LNu5ka936D5BnxYdc9J1w=";
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
        --replace 'pypresence @ git+https://github.com/polyipseity/ext.pypresence.git@e941a582d0aa920d5e51301fbc9744d6ab4a9603' \
                  'pypresence'
    '';

    doCheck = false;
  };
in
{
  config = lib.mkMerge [
    {
      home.packages = [ discord-music-rpc ];

      # Out-of-store symlink so edits take effect without rebuild, matching the
      # Windows approach.  The source is marked immutable (macOS uchg) because
      # the app overwrites its config on startup and the writable symlink would
      # let writes reach the tracked file.
      home.file.".config/discord-music-rpc/config.yaml".source =
        config.lib.file.mkOutOfStoreSymlink "${builtins.getEnv "NUCLEUS_REPO_ROOT"}/src/modules/configs/discord-music-rpc/config.yaml";
    }

    # macOS: mark the source file immutable so the app cannot discard managed
    # settings through the writable out-of-store symlink.
    (lib.mkIf (pkgs.stdenv.isDarwin && userEnable) {
      home.activation.protectDiscordMusicRPCConfig = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        /usr/bin/chflags uchg "${builtins.getEnv "NUCLEUS_REPO_ROOT"}/src/modules/configs/discord-music-rpc/config.yaml" 2>/dev/null || true
      '';
    })

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
