# Cross-platform shared package set.
{
  config,
  lib,
  pkgs,
  options,
  hostName,
  treefmtPackage ? null,
  ...
}:
let
  # Shared package registry. Each package is declared once with its full
  # cross-platform metadata. `nixpkgs` is the attribute name, `homebrew` is an
  # optional { kind = "formula"|"cask"; name }, `winget` an optional WinGet id.
  # `platforms` filters the nix provisioning axis and defaults to both darwin
  # and linux. `enable` is a per-host provisioning map, distinct from
  # `platforms`, and an absent host defaults to enabled so new hosts cannot
  # silently diverge. cli routes to nixpkgs, gui to Homebrew on macOS and to
  # nixpkgs on NixOS; any GUI component makes an entry gui.
  # pkgs.cargo must not be added: it conflicts with pkgs.rustup over bin/cargo.
  # install-cargo-binstall-packages takes cargo as a store-path argument.
  managedPackages = {
    "7zip" = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "p7zip";
      };
      nixpkgs = "p7zip";
      winget = "7zip.7zip";
    };
    actionlint = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "actionlint";
      };
      nixpkgs = "actionlint";
      winget = "rhysd.actionlint";
    };
    "android-tools" = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "android-platform-tools";
      };
      nixpkgs = "android-tools";
      winget = "Google.PlatformTools";
    };
    asciinema = {
      category = "cli";
      nixpkgs = "asciinema";
    };
    bat = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "bat";
      };
      nixpkgs = "bat";
      winget = "sharkdp.bat";
    };
    blender = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "blender";
      };
      nixpkgs = "blender";
      winget = "BlenderFoundation.Blender";
    };
    bottom = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "bottom";
      };
      nixpkgs = "bottom";
      winget = "Clement.bottom";
    };
    bun = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "bun";
      };
      nixpkgs = "bun";
      winget = "Oven-sh.Bun";
    };
    caddy = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "caddy";
      };
      nixpkgs = "caddy";
      winget = "CaddyServer.Caddy";
    };
    camilladsp = {
      category = "cli";
      nixpkgs = "camilladsp";
    };
    "cargo-binstall" = {
      category = "cli";
      nixpkgs = "cargo-binstall";
    };
    "cargo-cache" = {
      category = "cli";
      nixpkgs = "cargo-cache";
    };
    "cargo-nextest" = {
      category = "cli";
      nixpkgs = "cargo-nextest";
    };
    "check-jsonschema" = {
      category = "cli";
      nixpkgs = "check-jsonschema";
    };
    "chrome-remote-desktop" = {
      # nixpkgs has no attr for this (nixpkgs#34084), so NixOS installs nothing.
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "chrome-remote-desktop-host";
      };
      winget = "Google.ChromeRemoteDesktopHost";
    };
    czkawka = {
      category = "gui";
      homebrew = {
        kind = "brew";
        name = "czkawka";
      };
      nixpkgs = "czkawka";
      winget = "qarmin.czkawka.cli";
    };
    exiftool = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "exiftool";
      };
      nixpkgs = "perlPackages.ImageExifTool";
      winget = "ExifTool.ExifTool";
    };
    mat2 = {
      category = "cli";
      nixpkgs = "mat2";
    };
    cursor = {
      # Single source of truth for Cursor enable/disable. Every host is listed
      # and disabled, since an omitted host would default to enabled.
      enable = {
        MacBook = false;
        NixOS = false;
        Windows = false;
      };
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "cursor";
      };
      # WHY: code-cursor is Linux-only (AppImage repack); macOS uses the Homebrew cask.
      nixpkgs = "code-cursor";
      winget = "Anysphere.Cursor";
    };
    deadnix = {
      category = "cli";
      nixpkgs = "deadnix";
    };
    desktoppr = {
      category = "cli";
      platforms = [ "darwin" ];
      nixpkgs = "desktoppr";
    };
    "discord@canary" = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "discord@canary";
      };
      nixpkgs = "discord-canary";
      winget = "Discord.Discord.Canary";
    };
    direnv = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "direnv";
      };
      nixpkgs = "direnv";
      winget = "direnv.direnv";
    };
    dos2unix = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "dos2unix";
      };
      nixpkgs = "dos2unix";
      winget = "waterlan.dos2unix";
    };
    "dotnet-runtime-6" = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "dotnet";
      };
      nixpkgs = "dotnetCorePackages.runtime_6_0";
      winget = "Microsoft.DotNet.Runtime.6";
    };
    duti = {
      category = "cli";
      platforms = [ "darwin" ];
      nixpkgs = "duti";
    };
    eza = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "eza";
      };
      nixpkgs = "eza";
      winget = "eza-community.eza";
    };
    "equaliser" = {
      category = "cli";
      platforms = [ "darwin" ];
    };
    "equalizer-apo" = {
      # WinGet-only: no Homebrew cask exists and no nixpkgs attr; Windows installs via WinGet.
      category = "gui";
      winget = "EqualizerAPO.EqualizerAPO";
    };
    ffmpeg = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "ffmpeg";
      };
      nixpkgs = "ffmpeg-full";
      winget = "Gyan.FFmpeg";
    };
    fd = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "fd";
      };
      nixpkgs = "fd";
      winget = "sharkdp.fd";
    };
    fzf = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "fzf";
      };
      nixpkgs = "fzf";
      winget = "junegunn.fzf";
    };
    "font-awesome" = {
      category = "cli";
      homebrew = {
        kind = "cask";
        name = "font-fontawesome";
      };
      nixpkgs = "font-awesome";
    };
    gh = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "gh";
      };
      nixpkgs = "gh";
      winget = "GitHub.cli";
    };
    gimp = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "gimp";
      };
      nixpkgs = "gimp";
      winget = "GIMP.GIMP";
    };
    git = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "git";
      };
      nixpkgs = "gitFull";
      winget = "Git.Git";
    };
    gnupg = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "gnupg";
      };
      nixpkgs = "gnupg";
      winget = "GnuPG.GnuPG";
    };
    "google-chrome" = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "google-chrome";
      };
      nixpkgs = "google-chrome";
      winget = "Google.Chrome";
    };
    "google-chrome@canary" = {
      # Why the stable attr is not the canary path: the canary ships via the
      # Homebrew cask on macOS and WinGet canary on Windows.
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "google-chrome@canary";
      };
      nixpkgs = "google-chrome";
      winget = "Google.Chrome.Canary";
    };
    ghostscript = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "ghostscript";
      };
      nixpkgs = "ghostscript";
      winget = "ArtifexSoftware.GhostScript";
    };
    imagemagick = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "imagemagick";
      };
      nixpkgs = "imagemagick";
      winget = "ImageMagick.ImageMagick";
    };
    inter = {
      category = "cli";
      homebrew = {
        kind = "cask";
        name = "font-inter";
      };
      nixpkgs = "inter";
      winget = "Inter.Inter";
    };
    iterm2 = {
      category = "gui";
      platforms = [ "darwin" ];
      homebrew = {
        kind = "cask";
        name = "iterm2";
      };
      nixpkgs = "iterm2";
    };
    jdk = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "openjdk@25";
      };
      nixpkgs = "jdk";
      winget = "EclipseAdoptium.Temurin.25.JDK";
    };
    jellyfin = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "jellyfin";
      };
      nixpkgs = "jellyfin";
      winget = "Jellyfin.Server";
    };
    "jetbrains-mono-nerd-font" = {
      category = "cli";
      homebrew = {
        kind = "cask";
        name = "font-jetbrains-mono-nerd-font";
      };
      nixpkgs = "nerd-fonts.jetbrains-mono";
      winget = "DEVCOM.JetBrainsMonoNerdFont";
    };
    jq = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "jq";
      };
      nixpkgs = "jq";
      winget = "jqlang.jq";
    };
    krita = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "krita";
      };
      nixpkgs = "krita";
      winget = "KDE.Krita";
    };
    krokiet = {
      # WinGet-only: no Homebrew cask exists and no nixpkgs attr; Windows installs via WinGet.
      category = "gui";
      winget = "qarmin.krokiet";
    };
    libreoffice = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "libreoffice";
      };
      nixpkgs = "libreoffice";
      winget = "TheDocumentFoundation.LibreOffice";
    };
    litellm = {
      category = "cli";
      nixpkgs = "litellm";
    };
    llvm = {
      # The top-level LLVM meta-package, distinct from the llvmPackages.* base entries.
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "llvm";
      };
      nixpkgs = "llvmPackages_latest.llvm";
      winget = "LLVM.LLVM";
    };
    "llvm-clang" = {
      category = "cli";
      nixpkgs = "llvmPackages.clang";
    };
    "llvm-lld" = {
      category = "cli";
      nixpkgs = "llvmPackages.lld";
    };
    "llvm-lldb" = {
      category = "cli";
      nixpkgs = "llvmPackages.lldb";
    };
    mas = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "mas";
      };
      platforms = [ "darwin" ];
    };
    mold = {
      category = "cli";
      nixpkgs = "mold";
    };
    "musicbrainz-picard" = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "musicbrainz-picard";
      };
      nixpkgs = "picard";
      winget = "MusicBrainz.Picard";
    };
    ncdu = {
      category = "cli";
      nixpkgs = "ncdu";
    };
    neovim = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "neovim";
      };
      nixpkgs = "neovim";
      winget = "Neovim.Neovim";
    };
    nickel = {
      category = "cli";
      nixpkgs = "nickel";
    };
    nixd = {
      category = "cli";
      nixpkgs = "nixd";
    };
    nixf = {
      category = "cli";
      nixpkgs = "nixf";
    };
    nixfmt = {
      category = "cli";
      nixpkgs = "nixfmt";
    };
    "nix-index" = {
      category = "cli";
      nixpkgs = "nix-index";
    };
    nls = {
      category = "cli";
      nixpkgs = "nls";
    };
    "noto-sans-cjk-sc" = {
      category = "cli";
      homebrew = {
        kind = "cask";
        name = "font-noto-sans-cjk-sc";
      };
      nixpkgs = "noto-fonts-cjk-sans";
      winget = "Google.NotoSans.CJK.SC";
    };
    "noto-sans-cjk-tc" = {
      category = "cli";
      homebrew = {
        kind = "cask";
        name = "font-noto-sans-cjk-tc";
      };
      nixpkgs = "noto-fonts-cjk-sans";
      winget = "Google.NotoSans.CJK.TC";
    };
    "noto-serif-cjk-sc" = {
      category = "cli";
      homebrew = {
        kind = "cask";
        name = "font-noto-serif-cjk-sc";
      };
      nixpkgs = "noto-fonts-cjk-serif";
      winget = "Google.NotoSerif.CJK.SC";
    };
    "noto-serif-cjk-tc" = {
      category = "cli";
      homebrew = {
        kind = "cask";
        name = "font-noto-serif-cjk-tc";
      };
      nixpkgs = "noto-fonts-cjk-serif";
      winget = "Google.NotoSerif.CJK.TC";
    };
    "obs-studio" = {
      # Stable OBS Studio: nixpkgs has no beta channel, so stable is uniform.
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "obs";
      };
      nixpkgs = "obs-studio";
      winget = "OBSProject.OBSStudio";
    };
    obsidian = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "obsidian";
      };
      nixpkgs = "obsidian";
      winget = "Obsidian.Obsidian";
    };
    ollama = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "ollama";
      };
      nixpkgs = "ollama";
      winget = "Ollama.Ollama";
    };
    opencode = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "opencode";
      };
      nixpkgs = "opencode";
      winget = "SST.opencode";
    };
    packer = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "packer";
      };
      nixpkgs = "packer";
      winget = "Hashicorp.Packer";
    };
    parsec = {
      # macOS cask is in MacBook/homebrew.nix; no nixpkgs attr, so it is not on nixpkgs.
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "parsec";
      };
      winget = "Parsec.Parsec";
    };
    "pay-respects" = {
      category = "cli";
      nixpkgs = "pay-respects";
    };
    "peace-equalizer-apo" = {
      # WinGet-only: no Homebrew cask exists and no nixpkgs attr; Windows installs via WinGet.
      category = "gui";
      winget = "PeterVerbeek.PeaceEqualizerAPO";
    };
    "pi-coding-agent" = {
      category = "cli";
      nixpkgs = "pi-coding-agent";
    };
    pinact = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "pinact";
      };
      nixpkgs = "pinact";
      winget = "suzuki-shunsuke.pinact";
    };
    "pinentry_mac" = {
      category = "cli";
      platforms = [ "darwin" ];
      nixpkgs = "pinentry_mac";
    };
    pass = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "pass";
      };
      nixpkgs = "pass";
      # WHY: pass-otp is not a top-level attr and pass loads it from
      # SYSTEM_EXTENSION_DIR. Contributing both would collide on bin/pass, so
      # the wrapper replaces the plain attr. `nixpkgs` stays the probe.
      nixpkgsPackage = pkgs.pass.withExtensions (extensions: [ extensions.pass-otp ]);
      winget = "GnuPG.pass";
    };
    pulseview = {
      # WHY: not in homebrew-core; nixpkgs builds cleanly on macOS/Linux. Windows provisioned via WinGet Sigrok.PulseView.
      category = "gui";
      nixpkgs = "pulseview";
      winget = "Sigrok.PulseView";
    };
    powershell = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "powershell";
      };
      nixpkgs = "powershell";
      winget = "Microsoft.PowerShell";
    };
    powertoys = {
      category = "gui";
      platforms = [ "linux" ];
      homebrew = {
        kind = "cask";
        name = "powertoys";
      };
      winget = "Microsoft.PowerToys";
    };
    powersession = {
      # WHY: absent from nixpkgs, so disable nix routing on the other hosts.
      enable = {
        MacBook = false;
        NixOS = false;
        Windows = true;
      };
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "powersession";
      };
      winget = "Watfaq.PowerSession";
    };
    prek = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "prek";
      };
      nixpkgs = "prek";
      winget = "j178.Prek";
    };
    python = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "python";
      };
      nixpkgs = "python3";
      winget = "Python.Python.3.13";
    };
    qtpass = {
      # WHY: the cask is broken on macOS, so route it to nixpkgs there.
      category = "gui";
      nixpkgs = "qtpass";
      winget = "IJHack.QtPass";
    };
    qemu = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "qemu";
      };
      nixpkgs = "qemu";
    };
    rectangle = {
      category = "gui";
      platforms = [ "darwin" ];
      homebrew = {
        kind = "cask";
        name = "rectangle";
      };
      nixpkgs = "rectangle";
    };
    rclone = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "rclone";
      };
      nixpkgs = "rclone";
      winget = "Rclone.Rclone";
    };
    redis = {
      category = "cli";
      nixpkgs = "redis";
      winget = "Redis.Redis";
    };
    rimsort = {
      category = "gui";
      nixpkgs = "rimsort";
      winget = "RimSort.RimSort";
    };
    ripgrep = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "ripgrep";
      };
      nixpkgs = "ripgrep";
      winget = "BurntSushi.ripgrep";
    };
    ruff = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "ruff";
      };
      nixpkgs = "ruff";
      winget = "astral-sh.ruff";
    };
    rustup = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "rustup";
      };
      nixpkgs = "rustup";
      winget = "Rustlang.Rustup";
    };
    "sandbox-runtime" = {
      category = "cli";
      nixpkgs = "sandbox-runtime";
    };
    sccache = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "sccache";
      };
      nixpkgs = "sccache";
      winget = "Mozilla.sccache";
    };
    shellcheck = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "shellcheck";
      };
      nixpkgs = "shellcheck";
      winget = "ShellCheck.ShellCheck";
    };
    shfmt = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "shfmt";
      };
      nixpkgs = "shfmt";
      # WHY: shfmt is a single static binary; no separate macOS cask exists.
      winget = "mvdan.shfmt";
    };
    sigrok-cli = {
      # WHY: absent from WinGet; provisioned via Scoop custom bucket on Windows.
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "sigrok-cli";
      };
      nixpkgs = "sigrok-cli";
    };
    sops = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "sops";
      };
      nixpkgs = "sops";
      winget = "SecretsOPerationS.SOPS";
    };
    "source-serif" = {
      category = "cli";
      homebrew = {
        kind = "cask";
        name = "font-source-serif";
      };
      nixpkgs = "source-serif";
      winget = "Adobe.SourceSerif4";
    };
    "ssh-to-age" = {
      category = "cli";
      nixpkgs = "ssh-to-age";
    };
    starship = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "starship";
      };
      nixpkgs = "starship";
      winget = "Starship.Starship";
    };
    stats = {
      category = "gui";
      platforms = [ "darwin" ];
      homebrew = {
        kind = "cask";
        name = "stats";
      };
      nixpkgs = "stats";
    };
    sqlite = {
      category = "cli";
      nixpkgs = "sqlite";
      winget = "SQLite.SQLite";
    };
    steam = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "steam";
      };
      nixpkgs = "steam";
      winget = "Valve.Steam";
    };
    steamcmd = {
      category = "cli";
      nixpkgs = "steamcmd";
      winget = "Valve.SteamCMD";
    };
    switchaudio-osx = {
      category = "cli";
      platforms = [ "darwin" ];
      homebrew = {
        kind = "formula";
        name = "switchaudio-osx";
      };
      nixpkgs = "switchaudio-osx";
    };
    scoop = {
      category = "cli";
      platforms = [ "linux" ];
      homebrew = {
        kind = "formula";
        name = "scoop";
      };
      winget = "Scoop.Scoop";
    };
    taplo = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "taplo";
      };
      nixpkgs = "taplo";
      winget = "tamasfe.taplo";
    };
    "telegram@beta" = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "telegram-desktop@beta";
      };
      nixpkgs = "telegram-desktop";
      winget = "Telegram.TelegramDesktop.Beta";
    };
    ty = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "ty";
      };
      nixpkgs = "ty";
      winget = "astral-sh.ty";
    };
    typst = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "typst";
      };
      nixpkgs = "typst";
      winget = "Typst.Typst";
    };
    "utm@beta" = {
      category = "gui";
      platforms = [ "darwin" ];
      homebrew = {
        kind = "cask";
        name = "utm@beta";
      };
      nixpkgs = "utm";
    };
    uv = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "uv";
      };
      nixpkgs = "uv";
      winget = "astral-sh.uv";
    };
    vlc = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "vlc";
      };
      nixpkgs = "vlc";
      winget = "VideoLAN.VLC";
    };
    "visual-studio-code" = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "visual-studio-code";
      };
      nixpkgs = "vscode";
      winget = "Microsoft.VisualStudioCode";
    };
    "visual-studio-code@insiders" = {
      # Also provisioned on Windows via WinGet; no attr for the insiders build.
      platforms = [ "darwin" ];
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "visual-studio-code@insiders";
      };
      winget = "Microsoft.VisualStudioCode.Insiders";
    };
    "whatsapp-beta" = {
      # Allow-list is source-agnostic: the converter matches `settings.id`
      # regardless of `source: msstore`.
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "whatsapp@beta";
      };
      winget = "9NBDXK71NK08";
    };
    # WHY: no `winget` id exists, so Windows takes the Scoop entry in
    # src/modules/packages/desired.json. Weights are pinned under `whisper`.
    whisper-cpp = {
      category = "cli";
      nixpkgs = "whisper-cpp";
    };
    winfsp = {
      category = "cli";
      platforms = [ "linux" ];
      homebrew = {
        kind = "formula";
        name = "winfsp";
      };
      winget = "WinFsp.WinFsp";
    };
    "windows-terminal-preview" = {
      category = "gui";
      platforms = [ "linux" ];
      homebrew = {
        kind = "cask";
        name = "windows-terminal-preview";
      };
      winget = "Microsoft.WindowsTerminal.Preview";
    };
    yamllint = {
      category = "cli";
      nixpkgs = "yamllint";
    };
    "yq-go" = {
      category = "cli";
      nixpkgs = "yq-go";
      winget = "MikeFarah.yq";
    };
    zizmor = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "zizmor";
      };
      nixpkgs = "zizmor";
      winget = "zizmor.zizmor";
    };
    zoom = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "zoom";
      };
      nixpkgs = "zoom-us";
      winget = "Zoom.Zoom";
    };
    zoxide = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "zoxide";
      };
      nixpkgs = "zoxide";
      winget = "ajeetdsouza.zoxide";
    };
  };

  packageConfig = config.nucleus.packages.selection;
  managedPackageNames = builtins.attrNames managedPackages;

  # WHY: `enable` takes hostName explicitly, so the Windows set resolves anywhere Nix runs.
  managedPackageEnabledForHost =
    hostName: packageName:
    let
      entry = managedPackages.${packageName};
      enableMap =
        entry.enable or {
          MacBook = true;
          NixOS = true;
          Windows = true;
        };
    in
    enableMap.${hostName} or true;

  # WHY no fallback: `config.networking.hostName` is unset inside the embedded
  # Home Manager eval, where reading it silently yields "" and defeats `enable`.
  currentHost = hostName;
  enabledManagedPackageNames = builtins.filter (managedPackageEnabledForHost currentHost) managedPackageNames;

  # CLI to nixpkgs, GUI to homebrew. Any GUI component makes an entry gui.
  defaultBackendForCategory = category: if category == "cli" then "nixpkgs" else "homebrew";

  # Priority: overrides > policy > global backend.
  resolvePackageBackend =
    packageName:
    if builtins.hasAttr packageName packageConfig.backendOverrides then
      builtins.getAttr packageName packageConfig.backendOverrides
    else if packageConfig.backend == "policy" then
      defaultBackendForCategory managedPackages.${packageName}.category
    else
      packageConfig.backend;

  managedPackageBackends = builtins.listToAttrs (
    map (packageName: {
      name = packageName;
      value = resolvePackageBackend packageName;
    }) enabledManagedPackageNames
  );

  # Platform compatibility check. Default (absent) is both darwin and linux.
  managedPackagePlatformCompatible =
    packageName:
    let
      entry = managedPackages.${packageName};
      platforms =
        entry.platforms or [
          "darwin"
          "linux"
        ];
    in
    if pkgs.stdenv.hostPlatform.isDarwin then
      lib.elem "darwin" platforms
    else if pkgs.stdenv.hostPlatform.isLinux then
      lib.elem "linux" platforms
    else
      true;

  # WHY split: hasAttr/getAttr treat a dotted string as one literal top-level
  # name, so nested attrs such as "llvmPackages_latest.llvm" need a path list.
  nixPkgsAttrPath =
    packageName:
    let
      attr = managedPackages.${packageName}.nixpkgs or null;
    in
    if attr == null then [ ] else lib.strings.splitString "." attr;

  # WHY reject the empty path: hasAttrByPath would read it as the whole pkgs
  # attrset for an entry that has no `nixpkgs` attribute.
  nixPackageAttrPresent =
    packageName:
    nixPkgsAttrPath packageName != [ ] && lib.hasAttrByPath (nixPkgsAttrPath packageName) pkgs;

  # Derivation for a nixpkgs-routed entry. `nixpkgsPackage` overrides the
  # derivation while `nixpkgs` stays the availability probe.
  # WHY getAttrFromPath: unlike attrByPath with a null default it throws on a
  # missing path, so an unresolvable entry fails loudly.
  managedNixPackageDerivation =
    packageName:
    managedPackages.${packageName}.nixpkgsPackage
      or (lib.getAttrFromPath (nixPkgsAttrPath packageName) pkgs);

  # Managed packages routed to nixpkgs but absent from pkgs (platform-specific).
  missingNixPackageAttrs = builtins.filter (
    packageName:
    (managedPackages.${packageName}.nixpkgs or null) != null
    && managedPackagePlatformCompatible packageName
    && (
      if pkgs.stdenv.hostPlatform.isDarwin then
        managedPackageBackends.${packageName} == "nixpkgs"
      else
        true
    )
    && !(lib.hasAttrByPath (nixPkgsAttrPath packageName) pkgs)
  ) enabledManagedPackageNames;

  # Cross-platform nixpkgs packages. macOS respects backend selection; NixOS
  # takes every platform-compatible package.
  # WHY meta.available: platforms is a coarse darwin/linux filter, while some
  # packages build for one Linux arch only. meta.available reads lazily and does
  # NOT trip check-meta's refusal assertion.

  # Excluded: a programs.* module already contributes these, and a second
  # derivation would collide in buildEnv's paths. Windows still uses WinGet.
  posixProgramsProvidedPackages = [
    "neovim"
  ];

  managedNixPackages = map managedNixPackageDerivation (
    if pkgs.stdenv.hostPlatform.isDarwin then
      builtins.filter (
        name:
        (managedPackages.${name}.nixpkgs or null) != null
        && managedPackageBackends.${name} == "nixpkgs"
        && managedPackagePlatformCompatible name
        && nixPackageAttrPresent name
        && !(builtins.elem name posixProgramsProvidedPackages)
      ) enabledManagedPackageNames
    else
      builtins.filter (
        name:
        (managedPackages.${name}.nixpkgs or null) != null
        && managedPackagePlatformCompatible name
        && nixPackageAttrPresent name
        && nixPackageAttrAvailable name
        && !(builtins.elem name posixProgramsProvidedPackages)
      ) enabledManagedPackageNames
  );

  # Whether the managed package's nixpkgs attribute is actually available on
  # the current platform (checks meta.available, defaulting to true when the
  # attribute or its meta is missing).
  nixPackageAttrAvailable =
    packageName:
    let
      attr = managedPackages.${packageName}.nixpkgs;
    in
    ((lib.attrByPath (lib.strings.splitString "." attr) null pkgs).meta.available or true);

  managedHomebrewBrews = lib.optionals pkgs.stdenv.hostPlatform.isDarwin (
    builtins.filter (name: name != null) (
      map (
        packageName:
        let
          meta = managedPackages.${packageName};
        in
        # WHY: WinGet-only entries drop `homebrew` but still resolve to the
        # homebrew backend, so the kind guard skips them.
        if
          managedPackageBackends.${packageName} == "homebrew"
          && managedPackagePlatformCompatible packageName
          && (meta.homebrew or null) != null
          && meta.homebrew.kind == "brew"
        then
          meta.homebrew.name
        else
          null
      ) enabledManagedPackageNames
    )
  );

  managedHomebrewCasks = lib.optionals pkgs.stdenv.hostPlatform.isDarwin (
    builtins.filter (name: name != null) (
      map (
        packageName:
        let
          meta = managedPackages.${packageName};
        in
        if
          managedPackageBackends.${packageName} == "homebrew"
          && managedPackagePlatformCompatible packageName
          && (meta.homebrew or null) != null
          && meta.homebrew.kind == "cask"
        then
          meta.homebrew.name
        else
          null
      ) enabledManagedPackageNames
    )
  );

  sharedPackages =
    managedNixPackages
    # WHY: the flake overlay is the only source, and a plain nixpkgs eval
    # (the nixos-generators guest) does not carry it.
    ++ (lib.optionals (pkgs ? camillagui-backend) [ pkgs.camillagui-backend ])
    ++ (lib.optionals (pkgs ? rimsort) [ pkgs.rimsort ])
    ++ lib.optional (treefmtPackage != null) treefmtPackage;
in
{
  options.nucleus.packages.selection = {
    backend = lib.mkOption {
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

    backendOverrides = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.enum [
          "homebrew"
          "nixpkgs"
        ]
      );
      # WHY: qtpass's Homebrew cask is broken/notarized on macOS; route it to
      # nixpkgs (pkgs.qtpass) there instead. Windows still uses WinGet; NixOS is
      # nixpkgs anyway, so this only changes macOS.
      default = {
        pulseview = "nixpkgs";
        qtpass = "nixpkgs";
      };
      example = {
        "google-chrome" = "nixpkgs";
      };
      description = ''
        Per-package override map for entries in core.nix version of this module.
        Keys are Homebrew package names (for example "visual-studio-code").
      '';
    };
  };

  options.nucleus.macos.homebrew = {
    brews = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      internal = true;
      description = "Core-generated Homebrew formula list for managed packages.";
    };

    casks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      internal = true;
      description = "Core-generated Homebrew cask list for managed packages.";
    };
  };

  options.nucleus.packages.enabled = lib.mkOption {
    type = lib.types.attrsOf lib.types.bool;
    default = { };
    internal = true;
    description = "Resolved per-host enable state for each managedPackages entry (current host).";
  };

  options.nucleus.windows = lib.mkOption {
    type = lib.types.submodule {
      options.wingetPackages = {
        packages = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          internal = true;
          description = "WinGet package IDs enabled for the Windows host, derived from managedPackages entries carrying a `winget` id and resolving enabled for Windows.";
        };
      };
    };
    default = { };
    internal = true;
    description = "Windows-specific generated state derived from the shared package registry.";
  };

  config = lib.mkMerge [
    {
      # WHY mkDefault: the signature default is not honoured, because the module
      # system resolves every functionArgs entry through `config._module.args`.
      # The wrapper src/flake.nix passes via specialArgs still wins.
      _module.args.treefmtPackage = lib.mkDefault null;
    }

    (lib.optionalAttrs (options ? environment && options.environment ? systemPackages) {
      environment.systemPackages = sharedPackages;
    })

    (lib.optionalAttrs (options ? home && options.home ? packages) { home.packages = sharedPackages; })

    {
      assertions = map (packageName: {
        assertion = missingNixPackageAttrs == [ ];
        message = "core.nix: package '${packageName}' routes to nixpkgs but pkgs.${
          managedPackages.${packageName}.nixpkgs
        } is unavailable on this platform.";
      }) missingNixPackageAttrs;
    }

    (lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
      nucleus.macos.homebrew.brews = managedHomebrewBrews;
      nucleus.macos.homebrew.casks = managedHomebrewCasks;
    })

    {
      # Resolved enable state for the current host (consumed by editors.nix etc.).
      nucleus.packages.enabled = lib.listToAttrs (
        map (n: {
          name = n;
          value = managedPackageEnabledForHost currentHost n;
        }) managedPackageNames
      );

      # WHY: WinGet is orthogonal to the nix `platforms` field, which governs
      # darwin/linux provisioning only.
      nucleus.windows.wingetPackages.packages = builtins.sort (a: b: a < b) (
        builtins.map (n: managedPackages.${n}.winget) (
          builtins.filter (
            n: (managedPackages.${n}.winget or null) != null && managedPackageEnabledForHost "Windows" n
          ) managedPackageNames
        )
      );
    }
  ];
}
