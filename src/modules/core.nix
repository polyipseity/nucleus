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
    pkgs.powershell
    pkgs.prek
    pkgs.python3
    pkgs.ripgrep
    pkgs.ruff
    pkgs.sccache
    pkgs.rustup
    pkgs.shellcheck
    pkgs.sops
    pkgs.ssh-to-age
    pkgs.ty
    pkgs.typst
    pkgs.uv
    pkgs.yamllint
    pkgs.yq-go
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
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "cursor";
      };
      # WHY: code-cursor is Linux-only (AppImage repack); macOS uses the Homebrew cask.
      nixpkgsAttr = "code-cursor";
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
    }) overlapPackageNames
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
  ) overlapPackageNames;

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
          ) overlapPackageNames
        else
          builtins.filter (name: platformCompatible name && overlapNixAttrAvailable name) overlapPackageNames
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
      ) overlapPackageNames
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
      ) overlapPackageNames
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
  ];
}
