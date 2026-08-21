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
  # Cross-platform shared package registry. Each package is declared exactly
  # once with full cross-platform metadata (nixpkgs attr, Homebrew, WinGet).
  # field: nixpkgs — nixpkgs attribute name (the package's derivation path).
  # field: homebrew — optional { kind = "formula"|"cask"; name = "..." }.
  # field: winget — optional WinGet package id string (e.g. "Anysphere.Cursor").
  # field: platforms — restrict to specific platforms (["darwin"] or ["linux"]).
  #   Buildability axis only; governs darwin/linux nix provisioning. Default
  #   (absent): both darwin and linux. Kept separate from `enable` (provisioning map).
  # field: enable — optional per-host provisioning map { MacBook = bool; NixOS = bool;
  #   Windows = bool }. Absent hosts default to enabled, so new hosts can never
  #   silently diverge. This is the single source of truth for enable/disable
  #   across all hosts. Distinct from `platforms`: `platforms` is the build-capability
  #   axis (which OS families can build/install the package); `enable` is the
  #   provisioning axis (whether the package is actually installed on a given host).
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
      # macOS cask chrome-remote-desktop-host is in MacBook/homebrew.nix; the
      # nixpkgs attr is linux-only, so it is not installed on darwin.
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "chrome-remote-desktop-host";
      };
      nixpkgs = "chrome-remote-desktop";
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
    cursor = {
      # Single source of truth for Cursor enable/disable across all hosts.
      # `enable` is the per-host provisioning map; every host is explicitly disabled,
      # so Cursor stays off everywhere (no host enables it). A host omitted from
      # `enable` would default to enabled, so all three are listed to prevent
      # silent divergence on new hosts.
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
      nixpkgs = "equaliser";
    };
    "equalizer-apo" = {
      # WinGet-only (no nixpkgs attr); Windows installs via WinGet.
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "equalizer-apo";
      };
      nixpkgs = "equalizer-apo";
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
      winget = "GnuPG.Gpg4win";
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
      # No nixpkgs attr (canary is a Homebrew cask / WinGet-only channel); the
      # macOS cask is declared in MacBook/homebrew.nix, so it is not on nixpkgs.
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
      # WinGet-only (no nixpkgs attr); Windows installs via WinGet.
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "krokiet";
      };
      nixpkgs = "krokiet";
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
      # Distinct from the llvmPackages.* clang/lldb/lld entries (separate base
      # entries below); this is the top-level LLVM meta-package.
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
      # Stable OBS Studio. Enabled on every platform (no beta channel exists in
      # nixpkgs, so stable is the uniform choice across macOS/NixOS/Windows).
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
      winget = "HashiCorp.Packer";
    };
    parsec = {
      # macOS cask is in MacBook/homebrew.nix; no nixpkgs attr, so it is not on nixpkgs.
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "parsec";
      };
      nixpkgs = "parsec";
      winget = "Parsec.Parsec";
    };
    "pay-respects" = {
      category = "cli";
      nixpkgs = "pay-respects";
    };
    "peace-equalizer-apo" = {
      # WinGet-only (no nixpkgs attr); Windows installs via WinGet.
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "peace-equalizer-apo";
      };
      nixpkgs = "peace-equalizer-apo";
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
      nixpkgs = "powertoys";
      winget = "Microsoft.PowerToys";
    };
    powersession = {
      # WinGet-only: absent from nixpkgs (darwin+linux) and Homebrew. Windows
      # installs via WinGet; disable nix/homebrew routing on the other hosts.
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
      nixpkgs = "powersession";
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
      # Installed via MacBook/homebrew.nix managedSystemPackages (Homebrew cask
      # is broken/notarized); not on nixpkgs to avoid a second install path.
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "qtpass";
      };
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
    steam = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "steam";
      };
      nixpkgs = "steam";
      winget = "Valve.Steam";
    };
    scoop = {
      category = "cli";
      platforms = [ "linux" ];
      homebrew = {
        kind = "formula";
        name = "scoop";
      };
      nixpkgs = "scoop";
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
      # Was darwin-only for nix; now also provisioned on Windows via WinGet.
      # No nixpkgs attr for the insiders build, so it is not on nixpkgs.
      platforms = [ "darwin" ];
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "visual-studio-code@insiders";
      };
      nixpkgs = "vscode-insiders";
      winget = "Microsoft.VisualStudioCode.Insiders";
    };
    "whatsapp-beta" = {
      # Allow-list is source-agnostic: the converter matches `settings.id`
      # regardless of `source: msstore`, so the Store id is a valid winget id.
      # macOS beta cask is in MacBook/homebrew.nix; no nixpkgs attr, so it is
      # not on nixpkgs.
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "whatsapp@beta";
      };
      nixpkgs = "whatsapp";
      winget = "9NBDXK71NK08";
    };
    winfsp = {
      category = "cli";
      platforms = [ "linux" ];
      homebrew = {
        kind = "formula";
        name = "winfsp";
      };
      nixpkgs = "winfsp";
      winget = "WinFsp.WinFsp";
    };
    "windows-terminal-preview" = {
      category = "gui";
      platforms = [ "linux" ];
      homebrew = {
        kind = "cask";
        name = "windows-terminal-preview";
      };
      nixpkgs = "windows-terminal-preview";
      winget = "Microsoft.WindowsTerminal.Preview";
    };
    yamllint = {
      category = "cli";
      nixpkgs = "yamllint";
    };
    "yq-go" = {
      category = "cli";
      nixpkgs = "yq-go";
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

  # Resolve whether a managed package is enabled for a given host.
  # `enable` is a per-host provisioning map; absent entries default to enabled, so new
  # hosts can never silently diverge. Host-agnostic: takes hostName explicitly
  # so the Windows-resolved set can be computed anywhere Nix runs (Windows itself
  # does not run Nix).
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

  # Current host. Resolved from the `hostName` module arg, which the flake
  # passes in every eval context (darwin/nixos specialArgs, home-manager
  # extraSpecialArgs). `config.networking.hostName` is unset inside the
  # embedded Home Manager eval, so reading it there silently yields "" and
  # defeats the per-host `enable` map — hence no fallback.
  currentHost = hostName;
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
    if pkgs.stdenv.hostPlatform.isDarwin then
      lib.elem "darwin" platforms
    else if pkgs.stdenv.hostPlatform.isLinux then
      lib.elem "linux" platforms
    else
      true;

  # Split a managed package's dotted `nixpkgs` attribute into a path list so it
  # can be resolved against the nested pkgs attrset. `builtins.hasAttr`/
  # `getAttr` treat a dotted string as a single literal top-level name and do
  # NOT traverse the path, so nested attrs (e.g. "llvmPackages_latest.llvm")
  # must be split first.
  nixPkgsAttrPath = packageName: lib.strings.splitString "." managedPackages.${packageName}.nixpkgs;

  # Managed packages routed to nixpkgs but absent from pkgs (platform-specific).
  missingNixPackageAttrs = builtins.filter (
    packageName:
    managedPackagePlatformCompatible packageName
    && (
      if pkgs.stdenv.hostPlatform.isDarwin then
        managedPackageBackends.${packageName} == "nixpkgs"
      else
        true
    )
    && !(lib.hasAttrByPath (nixPkgsAttrPath packageName) pkgs)
  ) enabledManagedPackageNames;

  # Cross-platform nixpkgs packages from the managed set.
  # On macOS: respects backend selection (only if routed to nixpkgs).
  # On NixOS: all platform-compatible packages go to nixpkgs unconditionally.
  # WHY meta.available: managedPackages.platforms is a coarse darwin/linux
  # filter, but some packages only build for one Linux arch (e.g. discord-canary
  # is x86_64-linux only; the nixos-generators guest builds aarch64-linux).
  # meta.available reads lazily and does NOT trigger check-meta's refusal
  # assertion, so filtering by it safely drops arch-incompatible packages.

  # Packages already contributed to the Home Manager / system path by a
  # dedicated programs.* module (e.g. programs.neovim) on POSIX hosts.
  # Listing them here too would add a second, conflicting derivation to
  # buildEnv's paths. Windows still provisions them via WinGet, and the
  # managedPackages entry is retained for settings lookup + parity tests.
  posixProgramsProvidedPackages = [
    "neovim"
  ];

  managedNixPackages = map (packageName: lib.attrByPath (nixPkgsAttrPath packageName) null pkgs) (
    if pkgs.stdenv.hostPlatform.isDarwin then
      builtins.filter (
        name:
        managedPackageBackends.${name} == "nixpkgs"
        && managedPackagePlatformCompatible name
        && !(builtins.elem name posixProgramsProvidedPackages)
      ) enabledManagedPackageNames
    else
      builtins.filter (
        name:
        managedPackagePlatformCompatible name
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
        if managedPackageBackends.${packageName} == "homebrew" && meta.homebrew.kind == "brew" then
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
          description = "WinGet package IDs enabled for the Windows host, derived from managedPackages entries carrying a `winget` id and resolving enabled for Windows.";
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

      # Windows-resolved WinGet ID set (host-agnostic; identical wherever Nix runs).
      # Windows installs via WinGet, an axis orthogonal to the nix `platforms`
      # field (which governs darwin/linux nix provisioning only). Any entry with
      # a `winget` id enabled for Windows enters the set regardless of `platforms`.
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
