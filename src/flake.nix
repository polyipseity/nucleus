{
  description = "Nucleus - Unified Declarative System Configuration";

  inputs = {
    darwin = {
      url = "github:lnl7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-vscode-extensions = {
      url = "github:nix-community/nix-vscode-extensions";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-homebrew.url = "github:zhaofengli/nix-homebrew";
    homebrew-core = {
      url = "github:homebrew/homebrew-core";
      flake = false;
    };
    homebrew-cask = {
      url = "github:homebrew/homebrew-cask";
      flake = false;
    };
    cirruslabs-cli = {
      url = "github:cirruslabs/homebrew-cli";
      flake = false;
    };
    smudge-smudge = {
      url = "github:smudge/homebrew-smudge";
      flake = false;
    };
    macos-fuse-t-cask = {
      url = "github:macos-fuse-t/homebrew-cask";
      flake = false;
    };
    zackelia-formulae = {
      url = "github:zackelia/homebrew-formulae";
      flake = false;
    };
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      treefmt-nix,
      cirruslabs-cli,
      darwin,
      home-manager,
      homebrew-cask,
      homebrew-core,
      nix-homebrew,
      nix-vscode-extensions,
      nixpkgs,
      nixos-generators,
      rust-overlay,
      smudge-smudge,
      sops-nix,
      macos-fuse-t-cask,
      zackelia-formulae,
      ...
    }:
    let
      repoRoot = ../.;

      loadUserRegistry =
        hostName:
        import ./modules/lib/users-registry.nix {
          lib = nixpkgs.lib;
          inherit repoRoot hostName;
        };

      usersMacBook = loadUserRegistry "MacBook";
      usersNixOS = loadUserRegistry "NixOS";

      # Primary user is platform-independent; derive from the macOS registry view.
      users = usersMacBook;

      # Filter users by isPrimary=true and extract the attr name.
      username = builtins.head (
        builtins.filter (name: users.${name}.isPrimary) (builtins.attrNames users)
      );

      # home-manager.users attrset: each user gets home.nix and sops-nix.
      mkHomeManagerUsers =
        hostName: userModulesPath: hostUsers:
        builtins.mapAttrs (name: user: {
          imports = [
            {
              _module.args = {
                inherit hostName;
                users = hostUsers;
                managedUser = user;
                managedUsername = name;
              };
            }
            userModulesPath
            sops-nix.homeManagerModules.sops
          ];
        }) hostUsers;

      # Supported architectures.
      systems = {
        linux = "x86_64-linux";
        mac = "aarch64-darwin";
      };

      mkPkgs =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          # .NET 6 is EOL upstream; keep pinned for EIDE/runtime compatibility.
          config.permittedInsecurePackages = [ "dotnet-runtime-6.0.36" ];

          overlays = [
            (_final: prev: {
              # Nix sandbox; ffmpeg-full's tests cover them.
              davs2 = prev.davs2.overrideAttrs (_: {
                doCheck = !prev.stdenv.hostPlatform.isDarwin;
              });
              kvazaar = prev.kvazaar.overrideAttrs (_: {
                doCheck = !prev.stdenv.hostPlatform.isDarwin;
              });
              lcevcdec = prev.lcevcdec.overrideAttrs (_: {
                doCheck = !prev.stdenv.hostPlatform.isDarwin;
              });
              openapv = prev.openapv.overrideAttrs (_: {
                doCheck = !prev.stdenv.hostPlatform.isDarwin;
              });
              openh264 = prev.openh264.overrideAttrs (_: {
                doCheck = !prev.stdenv.hostPlatform.isDarwin;
              });
              svt-av1 = prev.svt-av1.overrideAttrs (_: {
                doCheck = !prev.stdenv.hostPlatform.isDarwin;
              });
              uavs3d = prev.uavs3d.overrideAttrs (_: {
                doCheck = !prev.stdenv.hostPlatform.isDarwin;
              });
              vvenc = prev.vvenc.overrideAttrs (_: {
                doCheck = !prev.stdenv.hostPlatform.isDarwin;
              });
              xavs2 = prev.xavs2.overrideAttrs (_: {
                doCheck = !prev.stdenv.hostPlatform.isDarwin;
              });
              xeve = prev.xeve.overrideAttrs (_: {
                doCheck = !prev.stdenv.hostPlatform.isDarwin;
              });
              xevd = prev.xevd.overrideAttrs (_: {
                doCheck = !prev.stdenv.hostPlatform.isDarwin;
              });
              # WHY: nixpkgs frei0r 3.2.1 unconditionally depends on gavl → libdrm,
              # which breaks ffmpeg-full eval on Darwin. Gate gavl to Linux and disable
              # it via CMake until nixpkgs merges https://github.com/NixOS/nixpkgs/pull/549747.
              frei0r = prev.frei0r.overrideAttrs (oldAttrs: {
                buildInputs = [
                  prev.cairo
                  prev.opencv
                ]
                ++ prev.lib.optionals prev.config.cudaSupport [
                  prev.cudaPackages.cuda_cudart
                ]
                ++ prev.lib.optionals prev.stdenv.hostPlatform.isLinux [
                  prev.gavl
                ];
                cmakeFlags = (oldAttrs.cmakeFlags or [ ]) ++ [
                  (prev.lib.cmakeBool "WITHOUT_GAVL" (!prev.stdenv.hostPlatform.isLinux))
                ];
              });
            })
            (_final: prev: {
              equaliser = prev.stdenv.mkDerivation rec {
                pname = "equaliser";
                version = "1.3.3";

                sourceRoot = ".";

                nativeBuildInputs = [ prev.undmg ];

                src = prev.fetchurl {
                  url = "https://github.com/cvknage/equaliser/releases/download/v${version}/Equaliser-${version}.dmg";
                  hash = "sha256-L/W2Vw2DPkTzeHG2wciN7ORQYRN35dM5sHmnBTkzlLI=";
                };

                installPhase = ''
                  mkdir -p $out/Applications
                  cp -r *.app $out/Applications/
                '';

                meta = {
                  description = "System-wide parametric equaliser for Apple Silicon";
                  homepage = "https://github.com/cvknage/equaliser";
                  license = prev.lib.licenses.gpl3Only;
                  platforms = [ "aarch64-darwin" ];
                };
              };
            })
            (_final: prev: {
              # camillagui-backend is a PyInstaller one-file bundle: Python app
              # data is appended after Mach-O section boundaries, so stripping
              # removes the appended PKG archive.
              camillagui-backend = prev.stdenv.mkDerivation rec {
                pname = "camillagui-backend";
                version = "4.1.0";

                src =
                  if prev.stdenv.hostPlatform.isDarwin then
                    if prev.stdenv.hostPlatform.isAarch64 then
                      prev.fetchurl {
                        url = "https://github.com/HEnquist/camillagui-backend/releases/download/v${version}/bundle_macos_aarch64.tar.gz";
                        hash = "sha256-CdoLZUrvqhyYPwIIUk2av3aOihOuRnDWm8ZcF/1LT2M=";
                      }
                    else
                      prev.fetchurl {
                        url = "https://github.com/HEnquist/camillagui-backend/releases/download/v${version}/bundle_macos_intel.tar.gz";
                        hash = "sha256-RUDHi8Bbhpdydr6lGI+TCNTMqtlUyoJgtH0rG2x01kE=";
                      }
                  else if prev.stdenv.hostPlatform.isAarch64 then
                    prev.fetchurl {
                      url = "https://github.com/HEnquist/camillagui-backend/releases/download/v${version}/bundle_linux_aarch64.tar.gz";
                      hash = "sha256-mlQVtE3aWEePGN6f1XLt8JL2Wf1eRcvoCG/1ZI3Aidc=";
                    }
                  else
                    prev.fetchurl {
                      url = "https://github.com/HEnquist/camillagui-backend/releases/download/v${version}/bundle_linux_amd64.tar.gz";
                      hash = "sha256-hv083ldQOPMS7ee60JENxeRrl0yvwEjCYRXsPLn1R5I=";
                    };

                sourceRoot = "camillagui_backend";
                dontStrip = true;
                dontPatchELF = true;

                installPhase = ''
                  mkdir -p $out/libexec/camillagui-backend $out/bin
                  cp -r * $out/libexec/camillagui-backend/
                  ln -s $out/libexec/camillagui-backend/camillagui_backend $out/bin/camillagui-backend
                '';

                meta = {
                  description = "Web GUI for CamillaDSP";
                  homepage = "https://github.com/HEnquist/camillagui-backend";
                  license = prev.lib.licenses.mit;
                  platforms = [
                    "x86_64-linux"
                    "aarch64-linux"
                    "x86_64-darwin"
                    "aarch64-darwin"
                  ];
                };
              };
            })
            (_final: prev: {
              # Darwin fixup runs strip -S over all of $out/lib (including
              # site-packages). cctools/llvm-strip mis-handles .ico COFF data and
              # inflates icons to hundreds of MB. Remove once nixpkgs closes
              # https://github.com/NixOS/nixpkgs/pull/539458 (darwin stdenv
              # stripExclude for *.ico / *.cur).
              litellm = prev.litellm.overridePythonAttrs (_: {
                stripExclude = [
                  "*.ico"
                  "*.cur"
                ];
              });
            })
            (
              _final: prev:
              let
                # Pin GnuPG to 2.5.x so PQC/Kyber subkeys can be decrypted.
                # The nixpkgs 2.4.x patch stack is intentionally dropped here,
                # because those patches target the 2.4 branch only.
                gnupg25 = prev.callPackage "${nixpkgs}/pkgs/tools/security/gnupg/24.nix" {
                  enableMinimal = false;
                  guiSupport = prev.stdenv.hostPlatform.isDarwin;
                  pinentry = if prev.stdenv.hostPlatform.isDarwin then prev.pinentry_mac else prev.pinentry-gtk2;
                  withPcsc = true;
                  withTpm2Tss = !prev.stdenv.hostPlatform.isDarwin;
                };

                gnupg25_pinned = gnupg25.overrideAttrs (_old: rec {
                  version = "2.5.19";
                  src = prev.fetchurl {
                    url = "mirror://gnupg/gnupg/gnupg-${version}.tar.bz2";
                    hash = "sha256-ciqopCbdm0Tg0ZS3O/7jo+YX1lZ0zU0dBi5t8p8XiMY=";
                  };

                  doCheck = false;
                  patches = [ ];
                  postPatch = "";
                  env.NIX_CFLAGS_COMPILE = prev.lib.optionalString prev.stdenv.hostPlatform.isDarwin "-Wno-implicit-function-declaration -D_DARWIN_C_SOURCE";
                });
              in
              {
                gnupg = gnupg25_pinned;
                gnupg24 = gnupg25_pinned;
              }
            )
            # Expose writeNucleusShellApplication via pkgs so all module and
            # host files can use it without importing from flake.nix.
            (final: _prev: { writeNucleusShellApplication = writeNucleusShellApplication final; })
          ];
        };

      pkgsLinux = mkPkgs systems.linux;
      pkgsMac = mkPkgs systems.mac;

      # nixpkgs with rust-overlay, for devShells only (separate from mkPkgs
      # to avoid affecting the system/hm evaluations).
      mkDevPkgs =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = [ (import rust-overlay) ];
        };
      pkgsDevLinux = mkDevPkgs systems.linux;
      pkgsDevMac = mkDevPkgs systems.mac;

      # VS Code Marketplace derivations from nix-vscode-extensions, for
      # editors.nix (extensions not yet packaged in nixpkgs).
      vsCodeMarketplaceMac = nix-vscode-extensions.extensions.${systems.mac}.vscode-marketplace;
      vsCodeMarketplaceLinux = nix-vscode-extensions.extensions.${systems.linux}.vscode-marketplace;

      # Unified shell app builder. Uses script-tree for repo-root-relative script
      # paths (src/scripts/, src/platforms/, src/hosts/) and scripts-bundle for
      # scripts/ (user CLIs). Creates a thin wrapper at $out/bin/nucleus-${name}
      writeNucleusShellApplication =
        pkgs:
        {
          name,
          scriptName ? "scripts/${name}",
          runtimeInputs ? [ ],
          extraEnv ? { },
          text ? null,
          meta ? { },
        }:
        let
          inherit (pkgs) lib;
          thisScriptTree = pkgs.callPackage ./modules/lib/script-tree.nix { };
          thisScriptsBundle = pkgs.callPackage ./modules/lib/scripts-bundle.nix {
            scriptTree = thisScriptTree;
          };
        in
        pkgs.runCommand "${name}-nucleus-app"
          {
            strictDeps = true; # hermetic build
          }
          ''
            mkdir -p "$out/bin"

            # Uniform layout: mirror repo hierarchy as-is (deduplicated store paths).
            # Every call site gets the same $out/scripts + $out/src so SCRIPT_DIR-relative
            # resolution works identically from the store path. No per-call-site divergence.
            ln -s ${thisScriptsBundle}/scripts "$out/scripts"
            ln -s ${thisScriptTree}/src "$out/src"

            ${
              if text != null then
                ''
                  # Write script directly from text parameter — no mirror tree or exec-discovery.
                  cat > "$out/bin/nucleus-${name}" << 'WRAPPER'
                  #!${pkgs.runtimeShell}
                  set -euo pipefail
                  export PATH="${lib.makeBinPath runtimeInputs}:$PATH"
                  ${
                    let
                      envExports = lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") extraEnv;
                    in
                    if envExports == [ ] then "" else lib.concatStringsSep "\n" envExports + "\n"
                  }${text}
                  WRAPPER
                  chmod +x "$out/bin/nucleus-${name}"
                ''
              else
                ''
                  # Create thin wrapper. Resolve symlinks so it works through
                  # home-manager profile symlinks, then exec the store-bundled script.
                  cat > "$out/bin/nucleus-${name}" << 'WRAPPER'
                  #!${pkgs.runtimeShell}
                  set -euo pipefail
                  export PATH="${lib.makeBinPath runtimeInputs}:$PATH"
                  ${
                    let
                      envExports = lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") extraEnv;
                    in
                    if envExports == [ ] then "" else lib.concatStringsSep "\n" envExports + "\n"
                  }_self="$0"
                  while [ -h "$_self" ]; do
                    _target="$(readlink "$_self")"
                    case "$_target" in
                      /*) _self="$_target" ;;
                      *) _self="$(CDPATH="" cd -- "$(dirname -- "$_self")" && pwd -P)/$_target" ;;
                    esac
                  done
                  # $out/scripts + $out/src are always mirrored, so the store script is
                  # the single source of truth — no repo-root detection, no fallback.
                  _store_root="$(CDPATH="" cd -- "$(dirname -- "$_self")/.." && pwd)"
                  exec "$_store_root/${scriptName}.sh" "$@"
                  WRAPPER
                  chmod +x "$out/bin/nucleus-${name}"
                ''
            }
          ''
        // {
          inherit meta;
        };

      # Derive flake `apps` entries from the single nucleusApps registration so
      # PATH, `nix run`, and `packages` stay in lockstep. Keyed by the short name
      # (strip the `nucleus-` prefix); program points at the app's bin wrapper.
      mkNucleusAppsAsFlakeApps =
        apps:
        nixpkgs.lib.mapAttrs' (
          name: pkg:
          let
            short = nixpkgs.lib.removePrefix "nucleus-" name;
          in
          nixpkgs.lib.nameValuePair short {
            type = "app";
            program = "${pkg}/bin/${name}";
          }
        ) apps;

      mkTreefmtWrapper = _system: pkgs: treefmt-nix.lib.mkWrapper pkgs ./treefmt.nix;

      # Build the full set of nucleus app packages for a given package set.
      # Used by home-manager (home.packages) and flake packages output.
      # All user-facing CLIs source src/scripts/lib via SCRIPT_DIR-relative paths.
      mkNucleusApps =
        pkgs: treefmtWrapper:
        let
          nucleusApp = args: writeNucleusShellApplication pkgs args;
          # Single source of truth for managed macOS preference domains (see
          # preference-gc.nix). Exposed to nucleus-gc so `gc preferences` can
          # purge stale state without duplicating the list.
          managedPrefDomains = import ../platforms/macOS/modules/preference-gc.nix { };
        in
        {
          nucleus-apply = nucleusApp {
            name = "apply";
            scriptName = "src/scripts/apply";
            runtimeInputs = [
              pkgs.curl
              pkgs.gawk
              pkgs.git
              pkgs.jq
              pkgs.openssh
              pkgs.prek
              pkgs.sops
              pkgs.ssh-to-age
            ];
          };
          nucleus-ai = nucleusApp {
            name = "ai";
            runtimeInputs = [ pkgs.jq ];
          };
          nucleus-bootstrap = nucleusApp {
            name = "bootstrap";
            runtimeInputs = [ ];
          };
          nucleus-check = nucleusApp {
            name = "check";
            runtimeInputs = [
              pkgs.bash
              pkgs.git
              pkgs.jq
              pkgs.nixf
              pkgs.packer
              pkgs.powershell
              pkgs.check-jsonschema
              treefmtWrapper
              pkgs.yq-go
            ];
          };
          nucleus-cloud = nucleusApp {
            name = "cloud";
            runtimeInputs = [
              pkgs.git
              pkgs.jq
              pkgs.rclone
            ];
          };
          nucleus-config = nucleusApp {
            name = "config";
            runtimeInputs = [ pkgs.jq ];
          };
          nucleus-gs-pdf-opt = nucleusApp {
            name = "gs-pdf-opt";
            runtimeInputs = [ pkgs.ghostscript ];
          };
          nucleus-gc = nucleusApp {
            name = "gc";
            runtimeInputs = [
              pkgs.jq
              pkgs.gnugrep
              pkgs.home-manager
            ];
            extraEnv = {
              MANAGED_PREF_DOMAINS = builtins.concatStringsSep " " managedPrefDomains.resetUserPreferenceDomains;
            };
          };
          nucleus-svc = nucleusApp {
            name = "svc";
            runtimeInputs = [ pkgs.jq ];
          };
          nucleus-test = nucleusApp {
            name = "test";
            runtimeInputs = [
              pkgs.bash
              pkgs.findutils
              pkgs.git
              pkgs.powershell
              treefmtWrapper
            ];
          };
          nucleus-update = nucleusApp {
            name = "update";
            runtimeInputs = [
              pkgs.gnupg
              pkgs.sops
            ];
          };
          nucleus-vm = nucleusApp {
            name = "vm";
            runtimeInputs = [
              pkgs.android-tools
              pkgs.jq
            ];
          };
        };

      nucleusAppsMac = mkNucleusApps pkgsMac (mkTreefmtWrapper systems.mac pkgsMac);
      nucleusAppsLinux = mkNucleusApps pkgsLinux (mkTreefmtWrapper systems.linux pkgsLinux);

      # Daemon-only package: NOT a nucleus app (not in mkNucleusApps), so it is
      # never on PATH, via `nix run`, or in `packages`. Daemons resolve it by
      # store path through the per-host nucleusApps merge below.
      serviceWatchdogPkg = writeNucleusShellApplication pkgsLinux {
        name = "service-watchdog";
        scriptName = "src/scripts/services/service-watchdog";
        runtimeInputs = [ pkgsLinux.jq ];
      };

    in
    {
      # -----------------------------------------------------------------------
      # apps — runnable via `nix run .#<name>`.
      # Each host exposes:
      #   apply         — the main orchestration entry point
      #   darwin-rebuild / home-manager / nixos-rebuild — engine binaries
      #     pinned to the same nixpkgs revision used by this flake, so the
      #     apply script does not have to locate them from the system PATH.
      # -----------------------------------------------------------------------
      apps = {
        "${systems.mac}" = mkNucleusAppsAsFlakeApps nucleusAppsMac // {
          darwin-rebuild = {
            type = "app";
            program = "${darwin.packages.${systems.mac}.darwin-rebuild}/bin/darwin-rebuild";
          };
          nixos-generators = nixos-generators.apps.${systems.mac}.default;
        };
        "${systems.linux}" = mkNucleusAppsAsFlakeApps nucleusAppsLinux // {
          home-manager = {
            type = "app";
            program = "${home-manager.packages.${systems.linux}.home-manager}/bin/home-manager";
          };
          nixos-rebuild = {
            type = "app";
            program = "${pkgsLinux.nixos-rebuild}/bin/nixos-rebuild";
          };
          nixos-generators = nixos-generators.apps.${systems.linux}.default;
        };
      };

      # -----------------------------------------------------------------------
      # darwinConfigurations — nix-darwin host for the MacBook.
      # Home Manager is embedded as a nix-darwin module so that the single
      # `darwin-rebuild switch` command activates both system and user config.
      # -----------------------------------------------------------------------
      darwinConfigurations.MacBook = darwin.lib.darwinSystem {
        # Reuse the shared package set so allowUnfree policy from mkPkgs is
        # applied consistently to both system and embedded Home Manager evals.
        pkgs = pkgsMac;
        specialArgs = {
          hostName = "MacBook";
          inherit username;
          users = usersMacBook;
          inherit
            homebrew-core
            homebrew-cask
            cirruslabs-cli
            macos-fuse-t-cask
            smudge-smudge
            zackelia-formulae
            ;
          nucleusApps = nucleusAppsMac // {
            nucleus-service-watchdog = serviceWatchdogPkg;
          };
          treefmtPackage = mkTreefmtWrapper systems.mac pkgsMac;
        };
        system = systems.mac;
        modules = [
          ./hosts/MacBook/default.nix
          sops-nix.darwinModules.sops
          nix-homebrew.darwinModules.nix-homebrew
          home-manager.darwinModules.home-manager
          {
            # Preserve pre-existing dotfiles on first activation instead of
            # aborting when Home Manager would overwrite them.
            home-manager.backupFileExtension = "bak";

            # Share the system nixpkgs instance to avoid a duplicate evaluation.
            home-manager.useGlobalPkgs = true;
            # Install user packages into the user profile rather than /etc.
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = {
              hostName = "MacBook";
              inherit nixpkgs username;
              users = usersMacBook;
              nucleusApps = nucleusAppsMac // {
                nucleus-service-watchdog = serviceWatchdogPkg;
              };
              vsCodeMarketplace = vsCodeMarketplaceMac;
              treefmtPackage = mkTreefmtWrapper systems.mac pkgsMac;
            };
            home-manager.users = mkHomeManagerUsers "MacBook" ./modules/home.nix usersMacBook;
          }
        ];
      };

      # -----------------------------------------------------------------------
      # nixosConfigurations — NixOS host for the generic Linux machine.
      # Same Home Manager embedding pattern as the Darwin host.
      # -----------------------------------------------------------------------
      nixosConfigurations.NixOS = nixpkgs.lib.nixosSystem {
        # Keep NixOS evaluation aligned with the same pinned package set and
        # unfree policy used by the rest of the flake outputs.
        pkgs = pkgsLinux;
        specialArgs = {
          hostName = "NixOS";
          inherit username;
          users = usersNixOS;
          nucleusApps = nucleusAppsLinux // {
            nucleus-service-watchdog = serviceWatchdogPkg;
          };
          treefmtPackage = mkTreefmtWrapper systems.linux pkgsLinux;
        };
        system = systems.linux;
        modules = [
          ./hosts/NixOS/default.nix
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          {
            # Mirror the Darwin behavior so first switch is non-destructive when
            # user-owned files already exist at Home Manager target paths.
            home-manager.backupFileExtension = "bak";

            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = {
              hostName = "NixOS";
              inherit nixpkgs username;
              users = usersNixOS;
              nucleusApps = nucleusAppsLinux // {
                nucleus-service-watchdog = serviceWatchdogPkg;
              };
              vsCodeMarketplace = vsCodeMarketplaceLinux;
              treefmtPackage = mkTreefmtWrapper systems.linux pkgsLinux;
            };
            home-manager.users = mkHomeManagerUsers "NixOS" ./modules/home.nix usersNixOS;
          }
        ];
      };

      formatter = {
        "${systems.mac}" = mkTreefmtWrapper systems.mac pkgsMac;
        "${systems.linux}" = mkTreefmtWrapper systems.linux pkgsLinux;
      };

      # -----------------------------------------------------------------------
      # packages — installable via `nix profile add .#bootstrap-deps`.
      # bootstrap-deps is a symlink-joined set of the tools used for manual
      # secret lifecycle tasks during bootstrap (gnupg, sops, ssh-to-age).
      # -----------------------------------------------------------------------
      packages = {
        "${systems.mac}" = {
          treefmt = mkTreefmtWrapper systems.mac pkgsMac;
          bootstrap-deps = pkgsMac.symlinkJoin {
            name = "bootstrap-deps";
            paths = [
              pkgsMac.gnupg
              pkgsMac.sops
              pkgsMac.ssh-to-age
              (mkTreefmtWrapper systems.mac pkgsMac)
            ];
          };
        }
        // nucleusAppsMac;
        "${systems.linux}" = {
          treefmt = mkTreefmtWrapper systems.linux pkgsLinux;
          bootstrap-deps = pkgsLinux.symlinkJoin {
            name = "bootstrap-deps";
            paths = [
              pkgsLinux.gnupg
              pkgsLinux.sops
              pkgsLinux.ssh-to-age
              (mkTreefmtWrapper systems.linux pkgsLinux)
            ];
          };
        }
        // nucleusAppsLinux;
      };

      # -----------------------------------------------------------------------
      # winget-packages — Nix-generated list of WinGet package IDs that are
      # enabled for the Windows host, derived from the shared package registry
      # (managedPackages in core.nix). Committed as
      # src/hosts/Windows/system/winget-packages.json and consumed by apply.ps1
      # to filter packages.dsc.yml (Windows does not run Nix).
      # -----------------------------------------------------------------------
      winget-packages = pkgsMac.writeText "winget-packages.json" (
        let
          evaluated = nixpkgs.lib.evalModules {
            prefix = [ ];
            modules = [
              ./modules/core.nix
              {
                # core.nix reads this for macOS backend selection; harmless here.
                nucleus.packages.selection.backend = "policy";
              }
              # core.nix sets `assertions`; that option is normally provided by
              # NixOS/nix-darwin, so declare a stub for this standalone eval.
              {
                options.assertions = nixpkgs.lib.mkOption {
                  type = nixpkgs.lib.types.listOf nixpkgs.lib.types.attrs;
                  default = [ ];
                  internal = true;
                };
              }
            ];
            specialArgs = {
              lib = nixpkgs.lib;
              pkgs = pkgsMac;
              options = { };
              # core.nix resolves the current host from the `hostName` module arg.
              hostName = "Windows";
            };
          };
        in
        (import ./modules/lib/json.nix { lib = nixpkgs.lib; }).toSortedJSON {
          "$schema" = "./winget-packages.schema.json";
          packages = evaluated.config.nucleus.windows.wingetPackages.packages;
        }
      );

      # -----------------------------------------------------------------------
      # devShells — entered via `nix develop .#<name>` or auto-loaded by
      # nix-direnv when an .envrc with `use flake` is present.
      #
      #   default   — general development tools: bun (JS runtime), uv (Python
      #               package manager), Rust toolchain via rust-overlay (reads
      #               rust-toolchain.toml when present in the project root;
      #               falls back to the latest stable default otherwise), prek
      #               (Git hook manager for repos that opt in via prek.toml),
      #               treefmt (formatter multiplexer via treefmt-nix), powershell (pwsh) for pre-commit
      #               validation, and packer for VM template builds.
      #               Auto-loaded by nix-direnv from the repo root .envrc.
      #   bootstrap — bootstrap tool set (gnupg, sops, ssh-to-age) for manual
      #               secret lifecycle tasks during initial provisioning.
      # -----------------------------------------------------------------------
      devShells = {
        "${systems.mac}" = {
          default =
            let
              # Prefer the project's rust-toolchain.toml when present; fall back
              # to the latest stable default profile (cargo, rustc, clippy,
              # rustfmt).  rust-overlay parses the file and assembles a
              # Nix-patched toolchain distinct from the system pkgs.rustup install
              # so devShell toolchain versions are reproducible and version-pinned.
              rustToolchain =
                if builtins.pathExists ../rust-toolchain.toml then
                  pkgsDevMac.rust-bin.fromRustupToolchainFile ../rust-toolchain.toml
                else
                  pkgsDevMac.rust-bin.stable.latest.default;
            in
            pkgsDevMac.mkShell {
              packages = [
                pkgsDevMac.actionlint
                pkgsDevMac.bun
                (mkTreefmtWrapper systems.mac pkgsDevMac)
                pkgsDevMac.packer
                pkgsDevMac.pinact
                pkgsDevMac.powershell
                pkgsDevMac.prek
                rustToolchain
                pkgsDevMac.shfmt
                pkgsDevMac.taplo
                pkgsDevMac.uv
                pkgsDevMac.yamllint
                pkgsDevMac.zizmor
              ];
              # libiconv is required by the macOS linker when building Rust/C projects
              # (ld: library not found for -liconv). It is included in glibc on Linux
              # so no equivalent addition is needed in the Linux devShell.
              buildInputs = [ pkgsDevMac.libiconv ];
              # sccache-wrapped C/C++ compilers for non-CMake projects that
              # read CC/CXX directly. CMake projects use CMAKE_C_COMPILER_LAUNCHER
              # (set globally via env-catalog) instead.
              CC = "${pkgsDevMac.sccache}/bin/sccache ${pkgsDevMac.llvmPackages.clang}/bin/clang";
              CXX = "${pkgsDevMac.sccache}/bin/sccache ${pkgsDevMac.llvmPackages.clang}/bin/clang++";
              # Ensure EDITOR/VISUAL are always set to nvim inside the devShell.
              # When nix-direnv activates via `use flake`, its `nix print-dev-env`
              # does not inherit the parent shell's variables. If the parent shell
              # happens to have EDITOR=nano (from nix-darwin's mkDefault), direnv
              # will not correct it because the devShell derivation does not set
              # EDITOR.  Explicitly declaring these here makes print-dev-env emit
              # `export EDITOR="nvim"`, so direnv applies the right value.
              EDITOR = "nvim";
              VISUAL = "nvim";
            };
          bootstrap = pkgsMac.mkShell {
            packages = [
              pkgsMac.gnupg
              pkgsMac.sops
              pkgsMac.ssh-to-age
            ];
          };
        };
        "${systems.linux}" = {
          default =
            let
              rustToolchain =
                if builtins.pathExists ../rust-toolchain.toml then
                  pkgsDevLinux.rust-bin.fromRustupToolchainFile ../rust-toolchain.toml
                else
                  pkgsDevLinux.rust-bin.stable.latest.default;
            in
            pkgsDevLinux.mkShell {
              packages = [
                pkgsDevLinux.actionlint
                pkgsDevLinux.bun
                (mkTreefmtWrapper systems.linux pkgsDevLinux)
                pkgsDevLinux.packer
                pkgsDevLinux.pinact
                pkgsDevLinux.powershell
                pkgsDevLinux.prek
                rustToolchain
                pkgsDevLinux.shfmt
                pkgsDevLinux.taplo
                pkgsDevLinux.uv
                pkgsDevLinux.yamllint
                pkgsDevLinux.zizmor
              ];
              # sccache-wrapped C/C++ compilers for non-CMake projects that
              # read CC/CXX directly. CMake projects use CMAKE_C_COMPILER_LAUNCHER
              # (set globally via env-catalog) instead.
              CC = "${pkgsDevLinux.sccache}/bin/sccache ${pkgsDevLinux.llvmPackages.clang}/bin/clang";
              CXX = "${pkgsDevLinux.sccache}/bin/sccache ${pkgsDevLinux.llvmPackages.clang}/bin/clang++";
              # Same rationale as the macOS devShell: force a correct EDITOR/VISUAL
              # so that nix-direnv activation does not inherit stale values from
              # the parent shell (e.g. nix-darwin's /etc/zshenv default).
              EDITOR = "nvim";
              VISUAL = "nvim";
            };
          bootstrap = pkgsLinux.mkShell {
            packages = [
              pkgsLinux.gnupg
              pkgsLinux.sops
              pkgsLinux.ssh-to-age
            ];
          };
        };
      };

      # -----------------------------------------------------------------------
      # homeConfigurations — standalone Home Manager profile.
      # Used on plain Linux and WSL where neither NixOS nor nix-darwin manages
      # the system layer.  Evaluated against the Linux package set so the same
      # profile can be applied to WSL (which is x86_64-linux) without changes.
      # -----------------------------------------------------------------------
      homeConfigurations.${username} = home-manager.lib.homeManagerConfiguration {
        extraSpecialArgs = {
          hostName = "NixOS";
          inherit nixpkgs username;
          users = usersNixOS;
          vsCodeMarketplace = vsCodeMarketplaceLinux;
        };
        modules = [
          {
            _module.args = {
              hostName = "NixOS";
              managedUsername = username;
              managedUser = usersNixOS.${username};
            };
          }
          sops-nix.homeManagerModules.sops
          ./modules/home.nix
        ];
        pkgs = pkgsLinux;
      };
    };
}
