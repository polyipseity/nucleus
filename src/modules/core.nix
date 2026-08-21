# Cross-platform shared package set.
{
  config,
  lib,
  pkgs,
  options,
  treefmtPackage ? null,
  ...
}:
let
  baseSharedPackages = [
    pkgs.android-tools
    pkgs.actionlint
    pkgs.asciinema
    pkgs.bat
    pkgs.bottom
    pkgs.bun
    pkgs.caddy
    # REMOVED: pkgs.cargo conflicts with pkgs.rustup (both provide bin/cargo).
    # Activation script install-cargo-binstall-packages gets pkgs.cargo as
    # a store-path argument directly — no PATH dependency needed.
    pkgs.camilladsp
    pkgs.cargo-binstall
    pkgs.cargo-cache
    pkgs.cargo-nextest
    pkgs.check-jsonschema
    pkgs.deadnix
    pkgs.direnv
    pkgs.eza
    pkgs.fd
    pkgs.ffmpeg-full
    pkgs.fzf
    pkgs.dotnetCorePackages.runtime_6_0
    # pkgs.gemini-cli  # intentionally disabled per user request
    pkgs.gh
    pkgs.gitFull
    pkgs.gnupg
    pkgs.ghostscript
    pkgs.imagemagick
    pkgs.jellyfin
    pkgs.jq
    pkgs.litellm
    pkgs.llvmPackages.clang
    pkgs.llvmPackages.lldb
    pkgs.llvmPackages.lld
    pkgs.mold
    pkgs.ncdu
    pkgs.nickel
    pkgs.nixd
    pkgs.nixf
    pkgs.nixfmt
    pkgs.nix-index
    pkgs.nls
    pkgs.opencode
    pkgs.p7zip
    pkgs.packer
    pkgs.pay-respects
    pkgs.pi-coding-agent
    pkgs.pinact
    pkgs.powershell
    pkgs.prek
    pkgs.python3
    pkgs.ripgrep
    pkgs.ruff
    pkgs.sccache
    pkgs.rustup
    pkgs.shellcheck
    pkgs.shfmt
    pkgs.sops
    pkgs.ssh-to-age
    pkgs.taplo
    pkgs.ty
    pkgs.typst
    pkgs.uv
    pkgs.yamllint
    pkgs.yq-go
    pkgs.zizmor
    pkgs.zoxide
  ];

  darwinSharedPackages = lib.optionals pkgs.stdenv.isDarwin [
    pkgs.desktoppr
    pkgs.duti
    pkgs.pinentry_mac
    pkgs.equaliser
  ];

  # Packages available in both nixpkgs and Homebrew. Cross-platform by default.
  # field: platforms — restrict to specific platforms (["darwin"] or ["linux"]).
  #   Default (absent): both darwin and linux.
  # Category rules: cli → nixpkgs; gui → Homebrew (cask preferred) on macOS.
  #   On NixOS: all packages go to nixpkgs unconditionally.
  # If a package ships any GUI component (binary, UI, daemon), classify as "gui".
  overlappingPackages = {
    blender = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "blender";
      };
      nixpkgsAttr = "blender";
      winget = {
        id = "BlenderFoundation.Blender";
      };
    };
    czkawka = {
      category = "gui";
      homebrew = {
        kind = "brew";
        name = "czkawka";
      };
      nixpkgsAttr = "czkawka";
      winget = {
        id = "qarmin.czkawka.cli";
      };
    };
    "discord@canary" = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "discord@canary";
      };
      nixpkgsAttr = "discord-canary";
      winget = {
        id = "Discord.Discord.Canary";
      };
    };
    google-chrome = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "google-chrome";
      };
      nixpkgsAttr = "google-chrome";
      winget = {
        id = "Google.Chrome";
      };
    };
    iterm2 = {
      category = "gui";
      platforms = [ "darwin" ];
      homebrew = {
        kind = "cask";
        name = "iterm2";
      };
      nixpkgsAttr = "iterm2";
    };
    krita = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "krita";
      };
      nixpkgsAttr = "krita";
      winget = {
        id = "KDE.Krita";
      };
    };
    libreoffice = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "libreoffice";
      };
      nixpkgsAttr = "libreoffice";
      winget = {
        id = "TheDocumentFoundation.LibreOffice";
      };
    };
    obsidian = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "obsidian";
      };
      nixpkgsAttr = "obsidian";
      winget = {
        id = "Obsidian.Obsidian";
      };
    };
    "musicbrainz-picard" = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "musicbrainz-picard";
      };
      nixpkgsAttr = "picard";
      winget = {
        id = "MusicBrainz.Picard";
      };
    };
    qemu = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "qemu";
      };
      nixpkgsAttr = "qemu";
    };
    rectangle = {
      category = "gui";
      platforms = [ "darwin" ];
      homebrew = {
        kind = "cask";
        name = "rectangle";
      };
      nixpkgsAttr = "rectangle";
    };
    stats = {
      category = "gui";
      platforms = [ "darwin" ];
      homebrew = {
        kind = "cask";
        name = "stats";
      };
      nixpkgsAttr = "stats";
    };
    "utm@beta" = {
      category = "gui";
      platforms = [ "darwin" ];
      homebrew = {
        kind = "cask";
        name = "utm@beta";
      };
      nixpkgsAttr = "utm";
    };
    cursor = {
      # Single source of truth for Cursor enable/disable across all hosts.
      # `enable` is the default for every host; `hosts` is the opt-in per-host
      # override (precedence over `enable`). A host omitted from `hosts` falls
      # back to `enable`, so new hosts can never silently diverge. Cursor stays
      # disabled everywhere (no per-host override enables it).
      enable = false;
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "cursor";
      };
      # WHY: code-cursor is Linux-only (AppImage repack); macOS uses the Homebrew cask.
      nixpkgsAttr = "code-cursor";
      winget = {
        id = "Anysphere.Cursor";
      };
    };
    "obs-studio" = {
      # Stable OBS Studio. Enabled on every platform (no beta channel exists in
      # nixpkgs, so stable is the uniform choice across macOS/NixOS/Windows).
      enable = true;
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "obs";
      };
      nixpkgsAttr = "obs-studio";
      winget = {
        id = "OBSProject.OBSStudio";
      };
    };
    jdk = {
      # Latest JDK LTS (25 as of 2026-08). Floating LTS alias tracks future LTS.
      enable = true;
      category = "cli";
      homebrew = {
        kind = "cask";
        name = "openjdk@25";
      };
      nixpkgsAttr = "jdk";
      winget = {
        id = "EclipseAdoptium.Temurin.25.JDK";
      };
    };
    visual-studio-code = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "visual-studio-code";
      };
      nixpkgsAttr = "vscode";
      winget = {
        id = "Microsoft.VisualStudioCode";
      };
    };
    "visual-studio-code@insiders" = {
      # Was darwin-only for nix; now also provisioned on Windows via WinGet.
      # No nixpkgs attr for the insiders build, so skip the nix side.
      platforms = [ "darwin" ];
      skipNix = true;
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "visual-studio-code@insiders";
      };
      nixpkgsAttr = "vscode-insiders";
      winget = {
        id = "Microsoft.VisualStudioCode.Insiders";
      };
    };
    vlc = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "vlc";
      };
      nixpkgsAttr = "vlc";
      winget = {
        id = "VideoLAN.VLC";
      };
    };
    zoom = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "zoom";
      };
      nixpkgsAttr = "zoom-us";
      winget = {
        id = "Zoom.Zoom";
      };
    };

    # -----------------------------------------------------------------------
    # Completed cross-platform overlap entries. Each carries a `winget.id` so
    # the Windows allow-list (winget-packages.json) covers it. Entries whose
    # nixpkgsAttr is already installed by baseSharedPackages / a dedicated
    # module / fonts.nix set `skipNix = true` to avoid double-installing on
    # macOS/NixOS while still reaching the Windows allow-list.
    # -----------------------------------------------------------------------

    # --- NEW: cross-platform packages not yet in the registry ---
    "google-chrome@canary" = {
      # No nixpkgs attr (canary is a Homebrew cask / WinGet-only channel); the
      # macOS cask is declared in MacBook/homebrew.nix, so skip the nix side.
      skipNix = true;
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "google-chrome@canary";
      };
      nixpkgsAttr = "google-chrome";
      winget = {
        id = "Google.Chrome.Canary";
      };
    };
    "chrome-remote-desktop" = {
      # macOS cask chrome-remote-desktop-host is in MacBook/homebrew.nix; the
      # nixpkgs attr is linux-only, so skip the nix side to avoid a darwin eval
      # failure (overlapNixAttrAvailable guards linux anyway).
      skipNix = true;
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "chrome-remote-desktop-host";
      };
      nixpkgsAttr = "chrome-remote-desktop";
      winget = {
        id = "Google.ChromeRemoteDesktopHost";
      };
    };
    gimp = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "gimp";
      };
      nixpkgsAttr = "gimp";
      winget = {
        id = "GIMP.GIMP";
      };
    };
    qtpass = {
      # Installed via MacBook/homebrew.nix managedSystemPackages (Homebrew cask
      # is broken/notarized); skip the nix side to avoid a second install path.
      skipNix = true;
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "qtpass";
      };
      nixpkgsAttr = "qtpass";
      winget = {
        id = "IJHack.QtPass";
      };
    };
    neovim = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "neovim";
      };
      nixpkgsAttr = "neovim";
      winget = {
        id = "Neovim.Neovim";
      };
    };
    krokiet = {
      # WinGet-only (no nixpkgs attr); Windows installs via WinGet.
      skipNix = true;
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "krokiet";
      };
      nixpkgsAttr = "krokiet";
      winget = {
        id = "qarmin.krokiet";
      };
    };
    parsec = {
      # macOS cask is in MacBook/homebrew.nix; no nixpkgs attr, so skip nix.
      skipNix = true;
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "parsec";
      };
      nixpkgsAttr = "parsec";
      winget = {
        id = "Parsec.Parsec";
      };
    };
    "peace-equalizer-apo" = {
      # WinGet-only (no nixpkgs attr); Windows installs via WinGet.
      skipNix = true;
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "peace-equalizer-apo";
      };
      nixpkgsAttr = "peace-equalizer-apo";
      winget = {
        id = "PeterVerbeek.PeaceEqualizerAPO";
      };
    };
    "equalizer-apo" = {
      # WinGet-only (no nixpkgs attr); Windows installs via WinGet.
      skipNix = true;
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "equalizer-apo";
      };
      nixpkgsAttr = "equalizer-apo";
      winget = {
        id = "EqualizerAPO.EqualizerAPO";
      };
    };
    steam = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "steam";
      };
      nixpkgsAttr = "steam";
      winget = {
        id = "Valve.Steam";
      };
    };
    "telegram@beta" = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "telegram-desktop@beta";
      };
      nixpkgsAttr = "telegram-desktop";
      winget = {
        id = "Telegram.TelegramDesktop.Beta";
      };
    };
    powersession = {
      # WinGet-only (no nixpkgs attr); Windows installs via WinGet.
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "powersession";
      };
      nixpkgsAttr = "powersession";
      winget = {
        id = "Watfaq.PowerSession";
      };
    };

    # --- MSSTORE: WhatsApp Beta uses its Store id as the allow-list key ---
    "whatsapp-beta" = {
      # Allow-list is source-agnostic: the converter matches `settings.id`
      # regardless of `source: msstore`, so the Store id is a valid winget.id.
      # macOS beta cask is in MacBook/homebrew.nix; no nixpkgs attr, skip nix.
      skipNix = true;
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "whatsapp@beta";
      };
      nixpkgsAttr = "whatsapp";
      winget = {
        id = "9NBDXK71NK08";
      };
    };

    # --- WIN-ONLY: Windows infrastructure, never provisioned on macOS/NixOS ---
    powertoys = {
      skipNix = true;
      platforms = [ "linux" ];
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "powertoys";
      };
      nixpkgsAttr = "powertoys";
      winget = {
        id = "Microsoft.PowerToys";
      };
    };
    "windows-terminal-preview" = {
      skipNix = true;
      platforms = [ "linux" ];
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "windows-terminal-preview";
      };
      nixpkgsAttr = "windows-terminal-preview";
      winget = {
        id = "Microsoft.WindowsTerminal.Preview";
      };
    };
    scoop = {
      skipNix = true;
      platforms = [ "linux" ];
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "scoop";
      };
      nixpkgsAttr = "scoop";
      winget = {
        id = "Scoop.Scoop";
      };
    };
    winfsp = {
      skipNix = true;
      platforms = [ "linux" ];
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "winfsp";
      };
      nixpkgsAttr = "winfsp";
      winget = {
        id = "WinFsp.WinFsp";
      };
    };

    # --- DUP: already in baseSharedPackages / fonts.nix / dedicated modules ---
    # These carry a `winget.id` so the Windows allow-list covers them, but
    # `skipNix = true` prevents a second nix install (the real install path is
    # baseSharedPackages, fonts.nix, or a dedicated module).
    "7zip" = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "p7zip";
      };
      nixpkgsAttr = "p7zip";
      winget = {
        id = "7zip.7zip";
      };
    };
    gpg4win = {
      # Installed via baseSharedPackages (pkgs.gnupg); skip the nix side here.
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "gnupg";
      };
      nixpkgsAttr = "gnupg";
      winget = {
        id = "GnuPG.Gpg4win";
      };
    };
    zoxide = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "zoxide";
      };
      nixpkgsAttr = "zoxide";
      winget = {
        id = "ajeetdsouza.zoxide";
      };
    };
    ghostscript = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "ghostscript";
      };
      nixpkgsAttr = "ghostscript";
      winget = {
        id = "ArtifexSoftware.GhostScript";
      };
    };
    packer = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "packer";
      };
      nixpkgsAttr = "packer";
      winget = {
        id = "HashiCorp.Packer";
      };
    };
    uv = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "uv";
      };
      nixpkgsAttr = "uv";
      winget = {
        id = "astral-sh.uv";
      };
    };
    ruff = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "ruff";
      };
      nixpkgsAttr = "ruff";
      winget = {
        id = "astral-sh.ruff";
      };
    };
    ty = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "ty";
      };
      nixpkgsAttr = "ty";
      winget = {
        id = "astral-sh.ty";
      };
    };
    ripgrep = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "ripgrep";
      };
      nixpkgsAttr = "ripgrep";
      winget = {
        id = "BurntSushi.ripgrep";
      };
    };
    caddy = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "caddy";
      };
      nixpkgsAttr = "caddy";
      winget = {
        id = "CaddyServer.Caddy";
      };
    };
    bottom = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "bottom";
      };
      nixpkgsAttr = "bottom";
      winget = {
        id = "Clement.bottom";
      };
    };
    direnv = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "direnv";
      };
      nixpkgsAttr = "direnv";
      winget = {
        id = "direnv.direnv";
      };
    };
    starship = {
      # Installed by starship.nix (home.packages); skip the nix side here.
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "starship";
      };
      nixpkgsAttr = "starship";
      winget = {
        id = "Starship.Starship";
      };
    };
    eza = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "eza";
      };
      nixpkgsAttr = "eza";
      winget = {
        id = "eza-community.eza";
      };
    };
    git = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "git";
      };
      nixpkgsAttr = "gitFull";
      winget = {
        id = "Git.Git";
      };
    };
    gh = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "gh";
      };
      nixpkgsAttr = "gh";
      winget = {
        id = "GitHub.cli";
      };
    };
    ffmpeg = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "ffmpeg";
      };
      nixpkgsAttr = "ffmpeg-full";
      winget = {
        id = "Gyan.FFmpeg";
      };
    };
    imagemagick = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "imagemagick";
      };
      nixpkgsAttr = "imagemagick";
      winget = {
        id = "ImageMagick.ImageMagick";
      };
    };
    prek = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "prek";
      };
      nixpkgsAttr = "prek";
      winget = {
        id = "j178.Prek";
      };
    };
    jq = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "jq";
      };
      nixpkgsAttr = "jq";
      winget = {
        id = "jqlang.jq";
      };
    };
    jellyfin = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "jellyfin";
      };
      nixpkgsAttr = "jellyfin";
      winget = {
        id = "Jellyfin.Server";
      };
    };
    fzf = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "fzf";
      };
      nixpkgsAttr = "fzf";
      winget = {
        id = "junegunn.fzf";
      };
    };
    "dotnet-runtime-6" = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "dotnet";
      };
      nixpkgsAttr = "dotnetCorePackages.runtime_6_0";
      winget = {
        id = "Microsoft.DotNet.Runtime.6";
      };
    };
    powershell = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "powershell";
      };
      nixpkgsAttr = "powershell";
      winget = {
        id = "Microsoft.PowerShell";
      };
    };
    ollama = {
      # Installed by ai/default.nix (home.packages); skip the nix side here.
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "ollama";
      };
      nixpkgsAttr = "ollama";
      winget = {
        id = "Ollama.Ollama";
      };
    };
    bun = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "bun";
      };
      nixpkgsAttr = "bun";
      winget = {
        id = "Oven-sh.Bun";
      };
    };
    rclone = {
      # Installed by cloud-drives.nix (home.packages); skip the nix side here.
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "rclone";
      };
      nixpkgsAttr = "rclone";
      winget = {
        id = "Rclone.Rclone";
      };
    };
    actionlint = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "actionlint";
      };
      nixpkgsAttr = "actionlint";
      winget = {
        id = "rhysd.actionlint";
      };
    };
    rustup = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "rustup";
      };
      nixpkgsAttr = "rustup";
      winget = {
        id = "Rustlang.Rustup";
      };
    };
    sops = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "sops";
      };
      nixpkgsAttr = "sops";
      winget = {
        id = "SecretsOPerationS.SOPS";
      };
    };
    bat = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "bat";
      };
      nixpkgsAttr = "bat";
      winget = {
        id = "sharkdp.bat";
      };
    };
    fd = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "fd";
      };
      nixpkgsAttr = "fd";
      winget = {
        id = "sharkdp.fd";
      };
    };
    shellcheck = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "shellcheck";
      };
      nixpkgsAttr = "shellcheck";
      winget = {
        id = "ShellCheck.ShellCheck";
      };
    };
    opencode = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "opencode";
      };
      nixpkgsAttr = "opencode";
      winget = {
        id = "SST.opencode";
      };
    };
    pinact = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "pinact";
      };
      nixpkgsAttr = "pinact";
      winget = {
        id = "suzuki-shunsuke.pinact";
      };
    };
    python = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "python";
      };
      nixpkgsAttr = "python3";
      winget = {
        id = "Python.Python.3.13";
      };
    };
    typst = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "typst";
      };
      nixpkgsAttr = "typst";
      winget = {
        id = "Typst.Typst";
      };
    };
    taplo = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "taplo";
      };
      nixpkgsAttr = "taplo";
      winget = {
        id = "tamasfe.taplo";
      };
    };
    zizmor = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "zizmor";
      };
      nixpkgsAttr = "zizmor";
      winget = {
        id = "zizmor.zizmor";
      };
    };
    sccache = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "sccache";
      };
      nixpkgsAttr = "sccache";
      winget = {
        id = "Mozilla.sccache";
      };
    };
    shfmt = {
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "shfmt";
      };
      nixpkgsAttr = "shfmt";
      # WHY: shfmt is a single static binary; no separate macOS cask exists.
      winget = {
        id = "mvdan.shfmt";
      };
    };
    llvm = {
      # Multiple nixpkgs attrs (clang/lldb/lld); no single top-level attr. The
      # real install is baseSharedPackages (llvmPackages.*). Skip the nix side.
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "llvm";
      };
      nixpkgsAttr = "llvmPackages_latest.llvm";
      winget = {
        id = "LLVM.LLVM";
      };
    };
    "platform-tools" = {
      # Installed via baseSharedPackages (pkgs.android-tools); skip the nix side.
      skipNix = true;
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "android-platform-tools";
      };
      nixpkgsAttr = "android-tools";
      winget = {
        id = "Google.PlatformTools";
      };
    };

    # --- DUP: fonts already installed via fonts.nix (home.packages) ---
    "source-serif" = {
      skipNix = true;
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "font-source-serif";
      };
      nixpkgsAttr = "source-serif";
      winget = {
        id = "Adobe.SourceSerif4";
      };
    };
    "jetbrains-mono-nerd-font" = {
      skipNix = true;
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "font-jetbrains-mono-nerd-font";
      };
      nixpkgsAttr = "nerd-fonts.jetbrains-mono";
      winget = {
        id = "DEVCOM.JetBrainsMonoNerdFont";
      };
    };
    "noto-sans-cjk-sc" = {
      skipNix = true;
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "font-noto-sans-cjk-sc";
      };
      nixpkgsAttr = "noto-fonts-cjk-sans";
      winget = {
        id = "Google.NotoSans.CJK.SC";
      };
    };
    "noto-sans-cjk-tc" = {
      skipNix = true;
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "font-noto-sans-cjk-tc";
      };
      nixpkgsAttr = "noto-fonts-cjk-sans";
      winget = {
        id = "Google.NotoSans.CJK.TC";
      };
    };
    "noto-serif-cjk-sc" = {
      skipNix = true;
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "font-noto-serif-cjk-sc";
      };
      nixpkgsAttr = "noto-fonts-cjk-serif";
      winget = {
        id = "Google.NotoSerif.CJK.SC";
      };
    };
    "noto-serif-cjk-tc" = {
      skipNix = true;
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "font-noto-serif-cjk-tc";
      };
      nixpkgsAttr = "noto-fonts-cjk-serif";
      winget = {
        id = "Google.NotoSerif.CJK.TC";
      };
    };
    inter = {
      skipNix = true;
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "font-inter";
      };
      nixpkgsAttr = "inter";
      winget = {
        id = "Inter.Inter";
      };
    };
  };

  packageSelection = config.nucleus.macos.packageSelection;
  overlapPackageNames = builtins.attrNames overlappingPackages;

  # Resolve whether an overlap package is enabled for a given host.
  # Precedence: explicit per-host override (hosts.<host>) > global `enable` (default).
  # Host-agnostic: takes hostName explicitly so the Windows-resolved set can be
  # computed anywhere Nix runs (Windows itself does not run Nix).
  overlapEnabledForHost =
    hostName: packageName:
    let
      entry = overlappingPackages.${packageName};
      global = entry.enable or true;
      hostOverride = entry.hosts or { };
    in
    if builtins.hasAttr hostName hostOverride then builtins.getAttr hostName hostOverride else global;

  # Current host (MacBook/NixOS set networking.hostName).
  currentHost = config.networking.hostName or "";
  enabledOverlapPackageNames = builtins.filter (overlapEnabledForHost currentHost) overlapPackageNames;

  # CLI → nixpkgs, GUI → homebrew. If a package ships any GUI component, classify as "gui".
  defaultBackendFor = category: if category == "cli" then "nixpkgs" else "homebrew";

  # Priority: overrides > policy > global backend.
  resolveBackend =
    packageName:
    if builtins.hasAttr packageName packageSelection.overrides then
      builtins.getAttr packageName packageSelection.overrides
    else if packageSelection.overlapBackend == "policy" then
      defaultBackendFor overlappingPackages.${packageName}.category
    else
      packageSelection.overlapBackend;

  selectedOverlapBackends = builtins.listToAttrs (
    map (packageName: {
      name = packageName;
      value = resolveBackend packageName;
    }) enabledOverlapPackageNames
  );

  # Platform compatibility check: a package's `platforms` field restricts which
  # platforms receive it. Default (absent) = both darwin and linux.
  platformCompatible =
    packageName:
    let
      entry = overlappingPackages.${packageName};
      platforms =
        entry.platforms or [
          "darwin"
          "linux"
        ];
    in
    if pkgs.stdenv.isDarwin then
      lib.elem "darwin" platforms
    else if pkgs.stdenv.isLinux then
      lib.elem "linux" platforms
    else
      true;

  # Overlap packages routed to nixpkgs but absent from pkgs (platform-specific).
  missingNixAttrs = builtins.filter (
    packageName:
    platformCompatible packageName
    && (if pkgs.stdenv.isDarwin then selectedOverlapBackends.${packageName} == "nixpkgs" else true)
    && !(builtins.hasAttr overlappingPackages.${packageName}.nixpkgsAttr pkgs)
  ) enabledOverlapPackageNames;

  # Cross-platform nixpkgs packages from the overlap set.
  # On macOS: respects backend selection (only if routed to nixpkgs).
  # On NixOS: all platform-compatible packages go to nixpkgs unconditionally.
  # WHY meta.available: overlappingPackages.platforms is a coarse darwin/linux
  # filter, but some packages only build for one Linux arch (e.g. discord-canary
  # is x86_64-linux only; the nixos-generators guest builds aarch64-linux).
  # meta.available reads lazily and does NOT trigger check-meta's refusal
  # assertion, so filtering by it safely drops arch-incompatible packages.
  # Whether the overlap entry is installed by another path (baseSharedPackages,
  # a dedicated module, or fonts.nix) and must NOT be re-added here. Such entries
  # still carry a `winget.id` so the Windows allow-list covers them, but they
  # are skipped on the nixpkgs side to avoid double-installing.
  overlapNixSkipped = name: overlappingPackages.${name}.skipNix or false;

  overlapNixPackages =
    map (packageName: builtins.getAttr overlappingPackages.${packageName}.nixpkgsAttr pkgs)
      (
        if pkgs.stdenv.isDarwin then
          builtins.filter (
            name:
            !overlapNixSkipped name && selectedOverlapBackends.${name} == "nixpkgs" && platformCompatible name
          ) enabledOverlapPackageNames
        else
          builtins.filter (
            name: !overlapNixSkipped name && platformCompatible name && overlapNixAttrAvailable name
          ) enabledOverlapPackageNames
      );

  # Whether the overlap package's nixpkgs attribute is actually available on
  # the current platform (checks meta.available, defaulting to true when the
  # attribute or its meta is missing).
  overlapNixAttrAvailable =
    packageName:
    let
      attr = overlappingPackages.${packageName}.nixpkgsAttr;
    in
    (pkgs.${attr}.meta.available or true);

  overlapHomebrewBrews = lib.optionals pkgs.stdenv.isDarwin (
    builtins.filter (name: name != null) (
      map (
        packageName:
        let
          meta = overlappingPackages.${packageName};
        in
        if
          !overlapNixSkipped packageName
          && selectedOverlapBackends.${packageName} == "homebrew"
          && meta.homebrew.kind == "brew"
        then
          meta.homebrew.name
        else
          null
      ) enabledOverlapPackageNames
    )
  );

  overlapHomebrewCasks = lib.optionals pkgs.stdenv.isDarwin (
    builtins.filter (name: name != null) (
      map (
        packageName:
        let
          meta = overlappingPackages.${packageName};
        in
        if
          !overlapNixSkipped packageName
          && selectedOverlapBackends.${packageName} == "homebrew"
          && meta.homebrew.kind == "cask"
        then
          meta.homebrew.name
        else
          null
      ) enabledOverlapPackageNames
    )
  );

  sharedPackages =
    baseSharedPackages
    # WHY: camillagui-backend ships only via the nucleus flake overlay (a
    # PyInstaller bundle; vanilla nixpkgs has no such attribute).  The real
    # NixOS/Darwin hosts get it through mkPkgs' overlays, but standalone
    # evaluations like the nixos-generators guest build use plain nixpkgs, so
    # append it only when the evaluating package set actually provides it.
    ++ (lib.optionals (pkgs ? camillagui-backend) [ pkgs.camillagui-backend ])
    ++ lib.optional (treefmtPackage != null) treefmtPackage
    ++ darwinSharedPackages
    ++ overlapNixPackages;
in
{
  options.nucleus.macos.packageSelection = {
    overlapBackend = lib.mkOption {
      type = lib.types.enum [
        "homebrew"
        "nixpkgs"
        "policy"
      ];
      default = "policy";
      description = ''
        Backend used for macOS packages that exist in both nixpkgs and
        Homebrew. "policy" follows default routing (CLI → nixpkgs,
        GUI → Homebrew/cask). Packages with any GUI component
        are classified as "gui".
      '';
    };

    overrides = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.enum [
          "homebrew"
          "nixpkgs"
        ]
      );
      default = { };
      example = {
        "google-chrome" = "nixpkgs";
      };
      description = ''
        Per-package override map for entries in core.nix overlappingPackages.
        Keys are Homebrew package names (for example "visual-studio-code").
      '';
    };
  };

  options.nucleus.macos.generatedHomebrew = {
    brews = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      internal = true;
      description = "Core-generated Homebrew formula list for overlap packages.";
    };

    casks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      internal = true;
      description = "Core-generated Homebrew cask list for overlap packages.";
    };
  };

  options.nucleus.overlapEnabled = lib.mkOption {
    type = lib.types.attrsOf lib.types.bool;
    default = { };
    internal = true;
    description = "Resolved per-host enable state for each overlappingPackages entry (current host).";
  };

  options.nucleus.windows = lib.mkOption {
    type = lib.types.submodule {
      options.generatedWinget = {
        packages = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          internal = true;
          description = "WinGet package IDs enabled for the Windows host, derived from overlappingPackages entries carrying a `winget.id` and resolving enabled for Windows.";
        };
      };
    };
    default = { };
    internal = true;
    description = "Windows-specific generated state derived from the shared overlap registry.";
  };

  config = lib.mkMerge [
    (lib.optionalAttrs (options ? environment && options.environment ? systemPackages) {
      environment.systemPackages = sharedPackages;
    })

    (lib.optionalAttrs (options ? home && options.home ? packages) { home.packages = sharedPackages; })

    {
      assertions = map (packageName: {
        assertion = false;
        message = "core.nix: package '${packageName}' routes to nixpkgs but pkgs.${
          overlappingPackages.${packageName}.nixpkgsAttr
        } is unavailable on this platform.";
      }) missingNixAttrs;
    }

    (lib.mkIf pkgs.stdenv.isDarwin {
      nucleus.macos.generatedHomebrew.brews = overlapHomebrewBrews;
      nucleus.macos.generatedHomebrew.casks = overlapHomebrewCasks;
    })

    {
      # Resolved enable state for the current host (consumed by editors.nix etc.).
      nucleus.overlapEnabled = lib.listToAttrs (
        map (n: {
          name = n;
          value = overlapEnabledForHost currentHost n;
        }) overlapPackageNames
      );

      # Windows-resolved WinGet ID set (host-agnostic; identical wherever Nix runs).
      # Windows installs via WinGet, an axis orthogonal to the nix `platforms`
      # field (which governs darwin/linux nix provisioning only). Any entry with
      # a `winget.id` enabled for Windows enters the set regardless of `platforms`.
      nucleus.windows.generatedWinget.packages = builtins.sort (a: b: a < b) (
        builtins.map (n: overlappingPackages.${n}.winget.id) (
          builtins.filter (
            n: (overlappingPackages.${n}.winget or null) != null && overlapEnabledForHost "Windows" n
          ) overlapPackageNames
        )
      );
    }
  ];
}
