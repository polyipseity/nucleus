# Cross-platform shared package set.
{
  config,
  lib,
  pkgs,
  options,
  ...
}:
let
  baseSharedPackages = [
    pkgs.bat
    pkgs.bottom
    pkgs.bun
    pkgs.caddy
    pkgs.camilladsp
    pkgs.camillagui-backend
    pkgs.cargo-binstall
    pkgs.cargo-cache
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
    pkgs.ncdu
    pkgs.nickel
    pkgs.nixd
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
    pkgs.ripgrep
    pkgs.ruff
    pkgs.rustup
    pkgs.shellcheck
    pkgs.sops
    pkgs.ssh-to-age
    pkgs.ty
    pkgs.typst
    pkgs.uv
    pkgs.zoxide
  ];

  darwinSharedPackages = lib.optionals pkgs.stdenv.isDarwin [
    pkgs.desktoppr
    pkgs.duti
    pkgs.pinentry_mac
    pkgs.equaliser
  ];

  # Packages in both nixpkgs and Homebrew. macOS-only.
  # Category rules: cli → nixpkgs; gui → Homebrew (cask preferred).
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
      homebrew = {
        kind = "cask";
        name = "rectangle";
      };
      nixpkgsAttr = "rectangle";
    };
    stats = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "stats";
      };
      nixpkgsAttr = "stats";
    };
    utm = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "utm";
      };
      nixpkgsAttr = "utm";
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

  # Overlap packages routed to nixpkgs but absent from pkgs (platform-specific).
  missingNixAttrs = lib.optionals pkgs.stdenv.isDarwin (
    builtins.filter (
      packageName:
      selectedOverlapBackends.${packageName} == "nixpkgs"
      && !(builtins.hasAttr overlappingPackages.${packageName}.nixpkgsAttr pkgs)
    ) overlapPackageNames
  );

  overlapNixPackages = lib.optionals pkgs.stdenv.isDarwin (
    lib.concatMap (
      packageName:
      let
        meta = overlappingPackages.${packageName};
      in
      if selectedOverlapBackends.${packageName} == "nixpkgs" then
        [ (builtins.getAttr meta.nixpkgsAttr pkgs) ]
      else
        [ ]
    ) overlapPackageNames
  );

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

  sharedPackages = baseSharedPackages ++ darwinSharedPackages ++ overlapNixPackages;
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

    (lib.mkIf pkgs.stdenv.isDarwin {
      assertions = map (packageName: {
        assertion = false;
        message = "core.nix: packageSelection requests nixpkgs for `${packageName}`, but pkgs.${
          overlappingPackages.${packageName}.nixpkgsAttr
        } is unavailable on this platform.";
      }) missingNixAttrs;

      nucleus.macos.generatedHomebrew.brews = overlapHomebrewBrews;
      nucleus.macos.generatedHomebrew.casks = overlapHomebrewCasks;
    })
  ];
}
