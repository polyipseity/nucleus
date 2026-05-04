# modules/core.nix — Cross-platform package set shared by every managed host.
#
# The same list of packages is injected whether the caller is nix-darwin
# (system-level packages go into environment.systemPackages), NixOS (same
# option), or a standalone Home Manager profile (home.packages).  A runtime
# options-probe via lib.mkMerge + lib.mkIf lets this single module work in all
# three contexts without the caller having to know which option is appropriate.
{ config, lib, pkgs, options, ... }:
let
  # Packages installed on every host regardless of OS.
  #   bat        — syntax-highlighted cat replacement
  #   bottom     — cross-platform system monitor (btm)
  #   direnv     — per-directory env loader (shell integration in shell.nix)
  #   eza        — modern ls with colour and icons
  #   fd         — fast find replacement
  #   fzf        — fuzzy finder used by shell widgets and neovim
  #   git        — version control
  #   gnupg      — GPG for secret management and signing
  #   jq         — JSON processor used by activation scripts
  #   opencode   — AI-native coding agent and assistant
  #   prek       — pre-commit hook manager used by prek.toml
  #   ripgrep    — fast grep replacement
  #   rustup     — Rust toolchain manager
  #   sops       — secret encryption/decryption tool
  #   uv         — fast Python package/project manager
  #   zoxide     — smart cd (shell integration in shell.nix)
  baseSharedPackages = [
    pkgs.bat
    pkgs.bottom
    pkgs.direnv
    pkgs.eza
    pkgs.fd
    pkgs.fzf
    pkgs.git
    pkgs.gnupg
    pkgs.jq
    pkgs.opencode
    pkgs.prek
    pkgs.ripgrep
    pkgs.rustup
    pkgs.sops
    pkgs.uv
    pkgs.zoxide
  ];

  # Darwin-only CLI extras that should always remain in nixpkgs.
  #   desktoppr    — set desktop wallpaper from the command line
  #   duti         — set default application for a UTI (used in macos.nix)
  #   pinentry_mac — macOS-native GPG PIN entry dialog
  darwinSharedPackages = lib.optionals pkgs.stdenv.isDarwin [
    # Darwin-only extras:
    #   desktoppr    — set desktop wallpaper from the command line
    #   duti         — set default application for a UTI (used in macos.nix)
    #   pinentry_mac — macOS-native GPG PIN entry dialog
    pkgs.desktoppr
    pkgs.duti
    pkgs.pinentry_mac
  ];

  # macOS packages available in both nixpkgs and Homebrew.
  # Selection defaults follow AGENTS.md policy:
  #   CLI → nixpkgs
  #   GUI/hardware-integrated apps → Homebrew
  overlappingPackages = {
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
    obsidian = {
      category = "gui";
      homebrew = {
        kind = "cask";
        name = "obsidian";
      };
      nixpkgsAttr = "obsidian";
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
  };

  # Shorthand alias into the module option values set by the host config.
  packageSelection = config.nucleus.macos.packageSelection;
  # Sorted list of all overlap package names; iterated in the selection pipeline below.
  overlapPackageNames = builtins.attrNames overlappingPackages;

  # Policy function: maps a package category to its default backend.
  # CLI tools default to nixpkgs; GUI/hardware-integrated apps default to
  # Homebrew, following the AGENTS.md package selection policy.
  defaultBackendFor = category:
    if category == "cli" then "nixpkgs" else "homebrew";

  # Per-package backend resolver — applies in priority order:
  #   1. Explicit per-package override (packageSelection.overrides).
  #   2. Policy function (defaultBackendFor) when overlapBackend == "policy".
  #   3. Global backend setting ("homebrew" or "nixpkgs") otherwise.
  resolveBackend = packageName:
    if builtins.hasAttr packageName packageSelection.overrides then
      builtins.getAttr packageName packageSelection.overrides
    else if packageSelection.overlapBackend == "policy" then
      defaultBackendFor overlappingPackages.${packageName}.category
    else
      packageSelection.overlapBackend;

  # Resolved backend attrset for every overlap package:
  #   { "<package-name>" = "nixpkgs" | "homebrew"; }
  selectedOverlapBackends = builtins.listToAttrs (map
    (packageName: {
      name = packageName;
      value = resolveBackend packageName;
    })
    overlapPackageNames);

  # Validation list: overlap packages routed to nixpkgs but absent from the
  # current pkgs attrset (e.g. a package unavailable on this platform).
  # Non-empty causes an `assertions` failure at eval time via the config block.
  missingNixAttrs = lib.optionals pkgs.stdenv.isDarwin (builtins.filter
    (packageName:
      selectedOverlapBackends.${packageName} == "nixpkgs"
      && !(builtins.hasAttr overlappingPackages.${packageName}.nixpkgsAttr pkgs))
    overlapPackageNames);

  # Nix derivations for overlap packages resolved to the nixpkgs backend.
  # Empty list on non-Darwin hosts because the overlap policy is macOS-only.
  overlapNixPackages = lib.optionals pkgs.stdenv.isDarwin (lib.concatMap
    (packageName:
      let
        meta = overlappingPackages.${packageName};
      in
      if selectedOverlapBackends.${packageName} == "nixpkgs" then
        [ (builtins.getAttr meta.nixpkgsAttr pkgs) ]
      else
        [ ])
    overlapPackageNames);

  # Homebrew formula names (kind = "brew") for overlap packages on the homebrew
  # backend.  Passed to homebrew.nix via the generated module option so the
  # host does not need to list them manually.
  overlapHomebrewBrews = lib.optionals pkgs.stdenv.isDarwin (builtins.filter
    (name: name != null)
    (map
      (packageName:
        let
          meta = overlappingPackages.${packageName};
        in
        if selectedOverlapBackends.${packageName} == "homebrew" && meta.homebrew.kind == "brew" then
          meta.homebrew.name
        else
          null)
      overlapPackageNames));

  # Homebrew cask names (kind = "cask") for overlap packages on the homebrew
  # backend.  Passed to homebrew.nix via the generated module option so the
  # host does not need to list them manually.
  overlapHomebrewCasks = lib.optionals pkgs.stdenv.isDarwin (builtins.filter
    (name: name != null)
    (map
      (packageName:
        let
          meta = overlappingPackages.${packageName};
        in
        if selectedOverlapBackends.${packageName} == "homebrew" && meta.homebrew.kind == "cask" then
          meta.homebrew.name
        else
          null)
      overlapPackageNames));

  # Final merged package list installed on every host: shared base + Darwin
  # extras + any overlap packages resolved to the nixpkgs backend on Darwin.
  sharedPackages = baseSharedPackages ++ darwinSharedPackages ++ overlapNixPackages;
in
{
  options.nucleus.macos.packageSelection = {
    overlapBackend = lib.mkOption {
      type = lib.types.enum [ "homebrew" "nixpkgs" "policy" ];
      default = "policy";
      description = ''
        Backend used for macOS packages that exist in both nixpkgs and
        Homebrew. "policy" follows AGENTS.md defaults (CLI → nixpkgs,
        GUI/hardware-integrated apps → Homebrew).
      '';
    };

    overrides = lib.mkOption {
      type = lib.types.attrsOf (lib.types.enum [ "homebrew" "nixpkgs" ]);
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

  # Probe the module option tree at evaluation time to decide which option to
  # populate. optionalAttrs is used (instead of mkIf) for environment/home
  # branches so unknown option paths are omitted entirely on module stacks
  # where they do not exist (for example: home.* in pure system evaluations).
  # Both branches may match simultaneously (e.g. nix-darwin with Home Manager),
  # so mkMerge is used to merge both results safely.
  config = lib.mkMerge [
    (lib.optionalAttrs (options ? environment && options.environment ? systemPackages) {
      environment.systemPackages = sharedPackages;
    })

    (lib.optionalAttrs (options ? home && options.home ? packages) {
      home.packages = sharedPackages;
    })

    (lib.mkIf pkgs.stdenv.isDarwin {
      assertions = map
        (packageName: {
          assertion = false;
          message = "core.nix: packageSelection requests nixpkgs for `${packageName}`, but pkgs.${overlappingPackages.${packageName}.nixpkgsAttr} is unavailable on this platform.";
        })
        missingNixAttrs;

      nucleus.macos.generatedHomebrew.brews = overlapHomebrewBrews;
      nucleus.macos.generatedHomebrew.casks = overlapHomebrewCasks;
    })
  ];
}
