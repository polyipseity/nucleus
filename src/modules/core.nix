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
  # Cross-platform shared package registry. Each package is declared exactly
  # once with full cross-platform metadata (nixpkgs attr, Homebrew, WinGet).
  # field: platforms — restrict to specific platforms (["darwin"] or ["linux"]).
  #   Default (absent): both darwin and linux.
  # Category rules: cli → nixpkgs; gui → Homebrew (cask preferred) on macOS.
  #   On NixOS: all packages go to nixpkgs unconditionally.
  # If a package ships any GUI component (binary, UI, daemon), classify as "gui".
  # REMOVED: pkgs.cargo conflicts with pkgs.rustup (both provide bin/cargo).
  # Activation script install-cargo-binstall-packages gets pkgs.cargo as
  # a store-path argument directly — no PATH dependency needed.
  managedPackages = {
    "7zip" = {
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
    actionlint = {
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
    "android-tools" = {
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
    asciinema = {
      category = "cli";
      nixpkgsAttr = "asciinema";
    };
    bat = {
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
    bottom = {
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
    bun = {
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
    caddy = {
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
    camilladsp = {
      category = "cli";
      nixpkgsAttr = "camilladsp";
    };
    "cargo-binstall" = {
      category = "cli";
      nixpkgsAttr = "cargo-binstall";
    };
    "cargo-cache" = {
      category = "cli";
      nixpkgsAttr = "cargo-cache";
    };
    "cargo-nextest" = {
      category = "cli";
      nixpkgsAttr = "cargo-nextest";
    };
    "check-jsonschema" = {
      category = "cli";
      nixpkgsAttr = "check-jsonschema";
    };
    "chrome-remote-desktop" = {
      # macOS cask chrome-remote-desktop-host is in MacBook/homebrew.nix; the
      # nixpkgs attr is linux-only, so it is not installed on darwin.
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
    deadnix = {
      category = "cli";
      nixpkgsAttr = "deadnix";
    };
    desktoppr = {
      category = "cli";
      platforms = [ "darwin" ];
      nixpkgsAttr = "desktoppr";
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
    direnv = {
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
    "dotnet-runtime-6" = {
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
    duti = {
      category = "cli";
      platforms = [ "darwin" ];
      nixpkgsAttr = "duti";
    };
    eza = {
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
    "equaliser" = {
      category = "cli";
      platforms = [ "darwin" ];
      nixpkgsAttr = "equaliser";
    };
    "equalizer-apo" = {
      # WinGet-only (no nixpkgs attr); Windows installs via WinGet.
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
    ffmpeg = {
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
    fd = {
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
    fzf = {
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
    gh = {
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
    git = {
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
    gnupg = {
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
    "google-chrome" = {
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
    "google-chrome@canary" = {
      # No nixpkgs attr (canary is a Homebrew cask / WinGet-only channel); the
      # macOS cask is declared in MacBook/homebrew.nix, so it is not on nixpkgs.
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
    ghostscript = {
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
    imagemagick = {
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
    inter = {
      category = "cli";
      homebrew = {
        kind = "cask";
        name = "font-inter";
      };
      nixpkgsAttr = "inter";
      winget = {
        id = "Inter.Inter";
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
    jdk = {
      category = "cli";
      homebrew = {
        kind = "formula";
        name = "openjdk@25";
      };
      nixpkgsAttr = "jdk";
      winget = {
        id = "EclipseAdoptium.Temurin.25.JDK";
      };
    };
    jellyfin = {
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
    "jetbrains-mono-nerd-font" = {
      category = "cli";
      homebrew = {
        kind = "cask";
        name = "font-jetbrains-mono-nerd-font";
      };
      nixpkgsAttr = "nerd-fonts.jetbrains-mono";
      winget = {
        id = "DEVCOM.JetBrainsMonoNerdFont";
      };
    };
    jq = {
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
    krokiet = {
      # WinGet-only (no nixpkgs attr); Windows installs via WinGet.
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
    litellm = {
      category = "cli";
      nixpkgsAttr = "litellm";
    };
    llvm = {
      # Distinct from the llvmPackages.* clang/lldb/lld entries (separate base
      # entries below); this is the top-level LLVM meta-package.
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
    "llvm-clang" = {
      category = "cli";
      nixpkgsAttr = "llvmPackages.clang";
    };
    "llvm-lld" = {
      category = "cli";
      nixpkgsAttr = "llvmPackages.lld";
    };
    "llvm-lldb" = {
      category = "cli";
      nixpkgsAttr = "llvmPackages.lldb";
    };
    mold = {
      category = "cli";
      nixpkgsAttr = "mold";
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
    ncdu = {
      category = "cli";
      nixpkgsAttr = "ncdu";
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
    nickel = {
      category = "cli";
      nixpkgsAttr = "nickel";
    };
    nixd = {
      category = "cli";
      nixpkgsAttr = "nixd";
    };
    nixf = {
      category = "cli";
      nixpkgsAttr = "nixf";
    };
    nixfmt = {
      category = "cli";
      nixpkgsAttr = "nixfmt";
    };
    "nix-index" = {
      category = "cli";
      nixpkgsAttr = "nix-index";
    };
    nls = {
      category = "cli";
      nixpkgsAttr = "nls";
    };
    "noto-sans-cjk-sc" = {
      category = "cli";
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
      category = "cli";
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
      category = "cli";
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
      category = "cli";
      homebrew = {
        kind = "cask";
        name = "font-noto-serif-cjk-tc";
      };
      nixpkgsAttr = "noto-fonts-cjk-serif";
      winget = {
        id = "Google.NotoSerif.CJK.TC";
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
    ollama = {
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
    opencode = {
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
    packer = {
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
    parsec = {
      # macOS cask is in MacBook/homebrew.nix; no nixpkgs attr, so it is not on nixpkgs.
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
    "pay-respects" = {
      category = "cli";
      nixpkgsAttr = "pay-respects";
    };
    "peace-equalizer-apo" = {
      # WinGet-only (no nixpkgs attr); Windows installs via WinGet.
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
    "pi-coding-agent" = {
      category = "cli";
      nixpkgsAttr = "pi-coding-agent";
    };
    pinact = {
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
    "pinentry_mac" = {
      category = "cli";
      platforms = [ "darwin" ];
      nixpkgsAttr = "pinentry_mac";
    };
    powershell = {
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
    powertoys = {
      category = "gui";
      platforms = [ "linux" ];
      homebrew = {
        kind = "cask";
        name = "powertoys";
      };
      nixpkgsAttr = "powertoys";
      winget = {
        id = "Microsoft.PowerToys";
      };
    };
    powersession = {
      # WinGet-only (no nixpkgs attr); Windows installs via WinGet.
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
    prek = {
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
    python = {
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
    qtpass = {
      # Installed via MacBook/homebrew.nix managedSystemPackages (Homebrew cask
      # is broken/notarized); not on nixpkgs to avoid a second install path.
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
    rclone = {
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
    ripgrep = {
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
    ruff = {
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
    rustup = {
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
    sccache = {
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
    shellcheck = {
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
    shfmt = {
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
    sops = {
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
    "source-serif" = {
      category = "cli";
      homebrew = {
        kind = "cask";
        name = "font-source-serif";
      };
      nixpkgsAttr = "source-serif";
      winget = {
        id = "Adobe.SourceSerif4";
      };
    };
    "ssh-to-age" = {
      category = "cli";
      nixpkgsAttr = "ssh-to-age";
    };
    starship = {
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
    stats = {
      category = "gui";
      platforms = [ "darwin" ];
      homebrew = {
        kind = "cask";
        name = "stats";
      };
      nixpkgsAttr = "stats";
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
    scoop = {
      category = "cli";
      platforms = [ "linux" ];
      homebrew = {
        kind = "formula";
        name = "scoop";
      };
      nixpkgsAttr = "scoop";
      winget = {
        id = "Scoop.Scoop";
      };
    };
    taplo = {
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
    ty = {
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
    typst = {
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
    "utm@beta" = {
      category = "gui";
      platforms = [ "darwin" ];
      homebrew = {
        kind = "cask";
        name = "utm@beta";
      };
      nixpkgsAttr = "utm";
    };
    uv = {
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
    "visual-studio-code" = {
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
      # No nixpkgs attr for the insiders build, so it is not on nixpkgs.
      platforms = [ "darwin" ];
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
    "whatsapp-beta" = {
      # Allow-list is source-agnostic: the converter matches `settings.id`
      # regardless of `source: msstore`, so the Store id is a valid winget.id.
      # macOS beta cask is in MacBook/homebrew.nix; no nixpkgs attr, so it is
      # not on nixpkgs.
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
    winfsp = {
      category = "cli";
      platforms = [ "linux" ];
      homebrew = {
        kind = "formula";
        name = "winfsp";
      };
      nixpkgsAttr = "winfsp";
      winget = {
        id = "WinFsp.WinFsp";
      };
    };
    "windows-terminal-preview" = {
      category = "gui";
      platforms = [ "linux" ];
      homebrew = {
        kind = "cask";
        name = "windows-terminal-preview";
      };
      nixpkgsAttr = "windows-terminal-preview";
      winget = {
        id = "Microsoft.WindowsTerminal.Preview";
      };
    };
    yamllint = {
      category = "cli";
      nixpkgsAttr = "yamllint";
    };
    "yq-go" = {
      category = "cli";
      nixpkgsAttr = "yq-go";
    };
    zizmor = {
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
    zoxide = {
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
  };

  packageConfig = config.nucleus.packages.selection;
  managedPackageNames = builtins.attrNames managedPackages;

  # Resolve whether a managed package is enabled for a given host.
  # Precedence: explicit per-host override (hosts.<host>) > global `enable` (default).
  # Host-agnostic: takes hostName explicitly so the Windows-resolved set can be
  # computed anywhere Nix runs (Windows itself does not run Nix).
  managedPackageEnabledForHost =
    hostName: packageName:
    let
      entry = managedPackages.${packageName};
      global = entry.enable or true;
      hostOverride = entry.hosts or { };
    in
    if builtins.hasAttr hostName hostOverride then builtins.getAttr hostName hostOverride else global;

  # Current host (MacBook/NixOS set networking.hostName).
  currentHost = config.networking.hostName or "";
  enabledManagedPackageNames = builtins.filter (managedPackageEnabledForHost currentHost) managedPackageNames;

  # CLI → nixpkgs, GUI → homebrew. If a package ships any GUI component, classify as "gui".
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

  # Platform compatibility check: a package's `platforms` field restricts which
  # platforms receive it. Default (absent) = both darwin and linux.
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
    if pkgs.stdenv.isDarwin then
      lib.elem "darwin" platforms
    else if pkgs.stdenv.isLinux then
      lib.elem "linux" platforms
    else
      true;

  # Managed packages routed to nixpkgs but absent from pkgs (platform-specific).
  missingNixPackageAttrs = builtins.filter (
    packageName:
    managedPackagePlatformCompatible packageName
    && (if pkgs.stdenv.isDarwin then managedPackageBackends.${packageName} == "nixpkgs" else true)
    && !(builtins.hasAttr managedPackages.${packageName}.nixpkgsAttr pkgs)
  ) enabledManagedPackageNames;

  # Cross-platform nixpkgs packages from the managed set.
  # On macOS: respects backend selection (only if routed to nixpkgs).
  # On NixOS: all platform-compatible packages go to nixpkgs unconditionally.
  # WHY meta.available: managedPackages.platforms is a coarse darwin/linux
  # filter, but some packages only build for one Linux arch (e.g. discord-canary
  # is x86_64-linux only; the nixos-generators guest builds aarch64-linux).
  # meta.available reads lazily and does NOT trigger check-meta's refusal
  # assertion, so filtering by it safely drops arch-incompatible packages.
  managedNixPackages =
    map (packageName: builtins.getAttr managedPackages.${packageName}.nixpkgsAttr pkgs)
      (
        if pkgs.stdenv.isDarwin then
          builtins.filter (
            name: managedPackageBackends.${name} == "nixpkgs" && managedPackagePlatformCompatible name
          ) enabledManagedPackageNames
        else
          builtins.filter (
            name: managedPackagePlatformCompatible name && nixPackageAttrAvailable name
          ) enabledManagedPackageNames
      );

  # Whether the managed package's nixpkgs attribute is actually available on
  # the current platform (checks meta.available, defaulting to true when the
  # attribute or its meta is missing).
  nixPackageAttrAvailable =
    packageName:
    let
      attr = managedPackages.${packageName}.nixpkgsAttr;
    in
    (pkgs.${attr}.meta.available or true);

  managedHomebrewBrews = lib.optionals pkgs.stdenv.isDarwin (
    builtins.filter (name: name != null) (
      map (
        packageName:
        let
          meta = managedPackages.${packageName};
        in
        if managedPackageBackends.${packageName} == "homebrew" && meta.homebrew.kind == "brew" then
          meta.homebrew.name
        else
          null
      ) enabledManagedPackageNames
    )
  );

  managedHomebrewCasks = lib.optionals pkgs.stdenv.isDarwin (
    builtins.filter (name: name != null) (
      map (
        packageName:
        let
          meta = managedPackages.${packageName};
        in
        if managedPackageBackends.${packageName} == "homebrew" && meta.homebrew.kind == "cask" then
          meta.homebrew.name
        else
          null
      ) enabledManagedPackageNames
    )
  );

  sharedPackages =
    managedNixPackages
    # WHY: camillagui-backend ships only via the nucleus flake overlay (a
    # PyInstaller bundle; vanilla nixpkgs has no such attribute).  The real
    # NixOS/Darwin hosts get it through mkPkgs' overlays, but standalone
    # evaluations like the nixos-generators guest build use plain nixpkgs, so
    # append it only when the evaluating package set actually provides it.
    ++ (lib.optionals (pkgs ? camillagui-backend) [ pkgs.camillagui-backend ])
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
      default = { };
      example = {
        "google-chrome" = "nixpkgs";
      };
      description = ''
        Per-package override map for entries in core.nix managedPackages.
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
          description = "WinGet package IDs enabled for the Windows host, derived from managedPackages entries carrying a `winget.id` and resolving enabled for Windows.";
        };
      };
    };
    default = { };
    internal = true;
    description = "Windows-specific generated state derived from the shared package registry.";
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
          managedPackages.${packageName}.nixpkgsAttr
        } is unavailable on this platform.";
      }) missingNixPackageAttrs;
    }

    (lib.mkIf pkgs.stdenv.isDarwin {
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

      # Windows-resolved WinGet ID set (host-agnostic; identical wherever Nix runs).
      # Windows installs via WinGet, an axis orthogonal to the nix `platforms`
      # field (which governs darwin/linux nix provisioning only). Any entry with
      # a `winget.id` enabled for Windows enters the set regardless of `platforms`.
      nucleus.windows.wingetPackages.packages = builtins.sort (a: b: a < b) (
        builtins.map (n: managedPackages.${n}.winget.id) (
          builtins.filter (
            n: (managedPackages.${n}.winget or null) != null && managedPackageEnabledForHost "Windows" n
          ) managedPackageNames
        )
      );
    }
  ];
}
