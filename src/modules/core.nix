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
    };
    czkawka = {
      category = "gui";
      homebrew = {
        kind = "brew";
        name = "czkawka";
      };
      nixpkgsAttr = "czkawka";
    };
    "discord@canary" = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "discord@canary";
      };
      nixpkgsAttr = "discord-canary";
    };
    google-chrome = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "google-chrome";
      };
      nixpkgsAttr = "google-chrome";
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
    };
    libreoffice = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "libreoffice";
      };
      nixpkgsAttr = "libreoffice";
    };
    obsidian = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "obsidian";
      };
      nixpkgsAttr = "obsidian";
    };
    "musicbrainz-picard" = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "musicbrainz-picard";
      };
      nixpkgsAttr = "picard";
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
    };
    "visual-studio-code@insiders" = {
      category = "gui";
      platforms = [ "darwin" ];
      homebrew = {
        kind = "cask";
        name = "visual-studio-code@insiders";
      };
      nixpkgsAttr = "vscode-insiders";
    };
    vlc = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "vlc";
      };
      nixpkgsAttr = "vlc";
    };
    zoom = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "zoom";
      };
      nixpkgsAttr = "zoom-us";
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
  overlapNixPackages =
    map (packageName: builtins.getAttr overlappingPackages.${packageName}.nixpkgsAttr pkgs)
      (
        if pkgs.stdenv.isDarwin then
          builtins.filter (
            name: selectedOverlapBackends.${name} == "nixpkgs" && platformCompatible name
          ) enabledOverlapPackageNames
        else
          builtins.filter (
            name: platformCompatible name && overlapNixAttrAvailable name
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
        if selectedOverlapBackends.${packageName} == "homebrew" && meta.homebrew.kind == "brew" then
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
        if selectedOverlapBackends.${packageName} == "homebrew" && meta.homebrew.kind == "cask" then
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
      nucleus.windows.generatedWinget.packages = builtins.map (n: overlappingPackages.${n}.winget.id) (
        builtins.filter (
          n: (overlappingPackages.${n}.winget or null) != null && overlapEnabledForHost "Windows" n
        ) overlapPackageNames
      );
    }
  ];
}
