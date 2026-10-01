{
  description = "Nucleus - Unified Declarative System Configuration";

  inputs = {
    darwin = {
      url = "github:lnl7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    hermes-agent = {
      url = "github:NousResearch/hermes-agent/v2026.9.24";
      inputs.nixpkgs.follows = "nixpkgs";
      # WHY: v2026.8.31 is the first release exposing homeManagerModules.default
      # (PR #84178). The `voice` dependency group is excluded in src/modules/hermes-agent.nix.
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
    openai-tools = {
      url = "github:openai/homebrew-tools";
      flake = false;
    };
    smudge-smudge = {
      url = "github:smudge/homebrew-smudge";
      flake = false;
    };
    mac-app-util = {
      url = "github:hraban/mac-app-util";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      treefmt-nix,
      openai-tools,
      darwin,
      hermes-agent,
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
      mac-app-util,
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

      # WHY: the primary user is platform-independent, so any registry view works.
      users = usersMacBook;

      username = builtins.head (
        builtins.filter (name: users.${name}.isPrimary) (builtins.attrNames users)
      );

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
              mat2 = prev.mat2.overrideAttrs (_: {
                # pytest-check-hook registers pytestCheckPhase in preDistPhases,
                # not checkPhase, so doCheck has no effect. Disable it explicitly.
                dontUsePytestCheck = true;
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
              # WHY no strip: a PyInstaller bundle carries its Python data past the
              # Mach-O section boundaries, so stripping drops the appended PKG.
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
                  else if prev.stdenv.hostPlatform.isWindows then
                    prev.fetchurl {
                      url = "https://github.com/HEnquist/camillagui-backend/releases/download/v${version}/bundle_windows_amd64.zip";
                      hash = "sha256-rIyV8gLRy2dPLx+bfNdP8UQyIZOnw7dOyAIZXqEjEuo=";
                    }
                  else
                    prev.fetchurl {
                      url = "https://github.com/HEnquist/camillagui-backend/releases/download/v${version}/bundle_linux_amd64.tar.gz";
                      hash = "sha256-hv083ldQOPMS7ee60JENxeRrl0yvwEjCYRXsPLn1R5I=";
                    };

                sourceRoot = "camillagui_backend";
                dontStrip = true;
                dontPatchELF = true;

                installPhase =
                  if prev.stdenv.hostPlatform.isWindows then
                    ''
                      mkdir -p $out/libexec/camillagui-backend $out/bin
                      cp -r * $out/libexec/camillagui-backend/
                      # Windows needs no bin symlink: the setup script references libexec directly.
                    ''
                  else
                    ''
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
                    "x86_64-cygwin"
                    "x86_64-windows"
                  ];
                };
              };
            })
            (
              _final: prev:
              prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
                # WHY: tarballs extract to a RimSort.app/ bundle, which Spotlight and
                # launch services only discover under $out/Applications.
                rimsort = prev.stdenv.mkDerivation rec {
                  pname = "rimsort";
                  version = "1.12.0";

                  src =
                    if prev.stdenv.hostPlatform.isAarch64 then
                      prev.fetchurl {
                        url = "https://github.com/RimSort/RimSort/releases/download/v${version}/RimSort-v${version}-Darwin_arm64.tar.gz";
                        hash = "sha256-O7rJULzSvzaoO6sfSTYF4EQhBsvcmm86+UsKR6luMfM=";
                      }
                    else
                      prev.fetchurl {
                        url = "https://github.com/RimSort/RimSort/releases/download/v${version}/RimSort-v${version}-Darwin_x86_64.tar.gz";
                        hash = "sha256-QlMupXTqSgV084ZA3IrX7bM+Sv96PTxnJUICW/kSwvk=";
                      };

                  sourceRoot = ".";

                  installPhase = ''
                    mkdir -p $out/Applications
                    cp -r RimSort.app $out/Applications/
                  '';

                  meta = {
                    description = "RimWorld mod manager for sorting, filtering, and managing mod load order";
                    homepage = "https://github.com/RimSort/RimSort";
                    license = prev.lib.licenses.gpl3Only;
                    platforms = [
                      "aarch64-darwin"
                      "x86_64-darwin"
                    ];
                  };
                };
              }
            )
            (
              _final: prev:
              prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
                # WHY: nixpkgs ships only the Linux variant, and RimSort needs the
                # native binary at steamcmd_install_path without a runtime download.
                steamcmd = prev.stdenv.mkDerivation rec {
                  pname = "steamcmd";
                  version = "20180104";

                  src = prev.fetchurl {
                    url = "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz";
                    hash = "sha256-jswXyJiOWsrcx45jHEhJD3YVDy36ps+Ne0tnsJe9dTs=";
                  };

                  # WHY: the tarball extracts flat, so unpackPhase must not search for a directory.
                  preUnpack = ''
                    mkdir $name
                    cd $name
                    sourceRoot=.
                  '';

                  dontBuild = true;

                  installPhase = ''
                    mkdir -p $out/share/steamcmd
                    find . -type f -exec install -Dm 755 "{}" "$out/share/steamcmd/{}" \;
                  '';

                  meta = {
                    description = "Steam command-line tools";
                    homepage = "https://developer.valvesoftware.com/wiki/SteamCMD";
                    license = prev.lib.licenses.unfreeRedistributable;
                    platforms = [
                      "aarch64-darwin"
                      "x86_64-darwin"
                    ];
                  };
                };
              }
            )
            (_final: prev: {
              # WHY: Windows takes the GitHub release binary, which is on neither
              # WinGet nor Scoop.
              camilladsp = prev.stdenv.mkDerivation rec {
                pname = "camilladsp";
                version = "4.1.3";
                # WHY: the tarball is a single flat file, so unpackPhase must not search for a directory.
                sourceRoot = ".";

                src =
                  if prev.stdenv.hostPlatform.isDarwin then
                    if prev.stdenv.hostPlatform.isAarch64 then
                      prev.fetchurl {
                        url = "https://github.com/HEnquist/camilladsp/releases/download/v${version}/camilladsp-macos-aarch64.tar.gz";
                        hash = "sha256-cGKKx7ZvZ9oEUi6QQNSEwsvWHpN50ifFlfRtxhNVvvg=";
                      }
                    else
                      prev.fetchurl {
                        url = "https://github.com/HEnquist/camilladsp/releases/download/v${version}/camilladsp-macos-amd64.tar.gz";
                        hash = "sha256-tm/1/QNjRDQOEORgYOrweh+0W1wJL7pG8RZFdVAIVWQ=";
                      }
                  else if prev.stdenv.hostPlatform.isWindows then
                    prev.fetchurl {
                      url = "https://github.com/HEnquist/camilladsp/releases/download/v${version}/camilladsp-windows-amd64.zip";
                      hash = "sha256-2UneWsX8Eygt1HFV4KxnCHwJ3YS698fVaGFr/G5D0ZA=";
                    }
                  else
                    prev.fetchurl {
                      url = "https://github.com/HEnquist/camilladsp/releases/download/v${version}/camilladsp-linux-amd64.tar.gz";
                      hash = "sha256-VfXsLtgPzHmlQ2cvn4ms5FV9KQ2AWE7zHuBEIRG9CxE=";
                    };

                dontBuild = true;
                dontStrip = true;
                dontPatchELF = true;

                installPhase =
                  if prev.stdenv.hostPlatform.isWindows then
                    ''
                      mkdir -p $out/bin
                      cp camilladsp.exe $out/bin/
                    ''
                  else
                    ''
                      mkdir -p $out/bin
                      find . -type f -executable -exec install -Dm 755 "{}" "$out/bin/{}" \;
                    '';

                meta = {
                  description = "Cross-platform audio processing engine";
                  homepage = "https://github.com/HEnquist/camilladsp";
                  license = prev.lib.licenses.mit;
                  platforms = [
                    "x86_64-linux"
                    "aarch64-linux"
                    "x86_64-darwin"
                    "aarch64-darwin"
                    "x86_64-windows"
                  ];
                };
              };
            })
            (
              _final: prev:
              prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
              }
            )
            (_final: prev: {
              # WHY: Darwin strip inflates .ico/.cur files to hundreds of MB, so
              # exclude them until https://github.com/NixOS/nixpkgs/pull/539458 lands.
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
                # WHY: pinned to 2.5.x so PQC/Kyber subkeys decrypt. The nixpkgs
                # patch stack is dropped because it targets the 2.4 branch only.
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
            # WHY: the upstream Nix module's default package resolves through pkgs.
            hermes-agent.overlays.default
            # Exposed via pkgs so modules use it without importing from flake.nix.
            (final: _prev: { writeNucleusShellApplication = writeNucleusShellApplication final; })
          ];
        };

      pkgsLinux = mkPkgs systems.linux;
      pkgsMac = mkPkgs systems.mac;

      # WHY separate from mkPkgs: rust-overlay must not affect system or HM evals.
      mkDevPkgs =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = [ (import rust-overlay) ];
        };
      pkgsDevLinux = mkDevPkgs systems.linux;
      pkgsDevMac = mkDevPkgs systems.mac;

      # WHY nix-vscode-extensions: those extensions are not packaged in nixpkgs.
      vsCodeMarketplaceMac = nix-vscode-extensions.extensions.${systems.mac}.vscode-marketplace;
      vsCodeMarketplaceLinux = nix-vscode-extensions.extensions.${systems.linux}.vscode-marketplace;

      # Unified shell app builder. script-tree serves repo paths, scripts-bundle
      # serves scripts/. Wrapper lands at $out/bin/nucleus-${name}.
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

            # WHY: every call site gets the same $out/scripts + $out/src, so
            # SCRIPT_DIR-relative resolution behaves identically from the store.
            ln -s ${thisScriptsBundle}/scripts "$out/scripts"
            ln -s ${thisScriptTree}/src "$out/src"

            ${
              if text != null then
                ''
                  # Inlined body, so it inherits the strict mode set above (no exec boundary).
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
                  # Thin wrapper: resolve symlinks (profile links), then exec the store script.
                  # WHY the strict mode above stops here: shell options do not cross `exec`,
                  # so a store script that needs strict mode must set it in its own body.
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
                  # $out/scripts + $out/src are always mirrored, so the store script is the
                  # canonical path, no repo-root detection, no fallback.
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

      # WHY: apps derives from the single mkNucleusApps registration, so PATH,
      # `nix run`, and `packages` cannot drift apart. Key is the short name.
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

      # Single registration surface for every nucleus-* command.
      mkNucleusApps =
        pkgs: treefmtWrapper:
        let
          nucleusApp = args: writeNucleusShellApplication pkgs args;
          # WHY: nucleus-gc needs the domain list without importing preference-gc.nix.
          managedPrefDomains = import ./platforms/macOS/modules/preference-gc.nix { };
        in
        {
          nucleus-apply = nucleusApp {
            name = "apply";
            # Windows twin: scripts/apply.ps1.
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
              pkgs.actionlint
              pkgs.bash
              pkgs.git
              pkgs.jq
              pkgs.nixf
              pkgs.packer
              pkgs.pinact
              pkgs.powershell
              pkgs.check-jsonschema
              pkgs.shfmt
              pkgs.taplo
              treefmtWrapper
              pkgs.yamllint
              pkgs.yq-go
              pkgs.zizmor
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
          nucleus-utils = nucleusApp {
            name = "utils";
            runtimeInputs = [
              pkgs.ghostscript
              pkgs.perlPackages.ImageExifTool
              pkgs.python3
            ];
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
              pkgs.check-jsonschema
              pkgs.findutils
              pkgs.git
              pkgs.powershell
              # WHY: the runner image ships no zsh, and two suites need it.
              pkgs.zsh
              # WHY: android-config-tests needs zip, which Ubuntu does not ship.
              pkgs.zip
              # WHY: camilladsp-deviceselect parses YAML fixtures, and PATH is exported once.
              (pkgs.python3.withPackages (p: [ p.pyyaml ]))
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

      # WHY: apply.sh adds this to the flake-inputs profile after a successful
      # rebuild, so GC cannot prune the *-source paths the next evaluation needs.
      mkFlakeInputsPkg =
        pkgs: inputs:
        pkgs.runCommand "flake-inputs" { } (
          ''
            mkdir -p "$out"
          ''
          + pkgs.lib.concatStringsSep "\n" (
            pkgs.lib.mapAttrsToList (n: v: ''
              ln -s "${v}" "$out/${n}"
            '') inputs
          )
        );

      flakeInputsMac = {
        hermes-agent = hermes-agent;
        darwin = darwin;
        home-manager = home-manager;
        nix-vscode-extensions = nix-vscode-extensions;
        nixpkgs = nixpkgs;
        rust-overlay = rust-overlay;
        sops-nix = sops-nix;
        treefmt-nix = treefmt-nix;
        nix-homebrew = nix-homebrew;
        homebrew-core = homebrew-core;
        homebrew-cask = homebrew-cask;
        openai-tools = openai-tools;
        smudge-smudge = smudge-smudge;
        mac-app-util = mac-app-util;
        nixos-generators = nixos-generators;
        brew-src = nix-homebrew.inputs.brew-src;
        nixlib = nixos-generators.inputs.nixlib;
      };
      flakeInputsLinux = flakeInputsMac;

      # WHY per-host: a shared derivation would force a cross-system build no
      # configured builder can satisfy. Not a nucleus app, so never on PATH.
      serviceWatchdogPkgMac = writeNucleusShellApplication pkgsMac {
        name = "service-watchdog";
        scriptName = "src/scripts/services/service-watchdog";
        runtimeInputs = [ pkgsMac.jq ];
      };
      serviceWatchdogPkgLinux = writeNucleusShellApplication pkgsLinux {
        name = "service-watchdog";
        scriptName = "src/scripts/services/service-watchdog";
        runtimeInputs = [ pkgsLinux.jq ];
      };

    in
    {
      # WHY pin the engines here: the apply script must not find rebuild binaries on PATH.
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

      # Home Manager is embedded so one `darwin-rebuild switch` activates system and user config.
      darwinConfigurations.MacBook = darwin.lib.darwinSystem {
        # WHY share the set: one allowUnfree policy for system and embedded HM evals.
        pkgs = pkgsMac;
        specialArgs = {
          hostName = "MacBook";
          inherit username repoRoot;
          users = usersMacBook;
          inherit
            homebrew-core
            homebrew-cask
            openai-tools
            smudge-smudge
            ;
          nucleusApps = nucleusAppsMac // {
            nucleus-service-watchdog = serviceWatchdogPkgMac;
          };
          treefmtPackage = mkTreefmtWrapper systems.mac pkgsMac;
        };
        system = systems.mac;
        modules = [
          ./hosts/MacBook/default.nix
          sops-nix.darwinModules.sops
          ./modules/env/env-secrets-sops.nix
          nix-homebrew.darwinModules.nix-homebrew
          home-manager.darwinModules.home-manager
          {
            # WHY: a first activation must not abort on existing dotfiles.
            home-manager.backupFileExtension = "bak";

            # WHY: reuse the system instance instead of evaluating it twice.
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = {
              hostName = "MacBook";
              inherit nixpkgs username repoRoot;
              users = usersMacBook;
              hermes-agent = hermes-agent;
              mac-app-util = mac-app-util;
              nucleusApps = nucleusAppsMac // {
                nucleus-service-watchdog = serviceWatchdogPkgMac;
              };
              vsCodeMarketplace = vsCodeMarketplaceMac;
              treefmtPackage = mkTreefmtWrapper systems.mac pkgsMac;
            };
            home-manager.users = mkHomeManagerUsers "MacBook" ./modules/home.nix usersMacBook;
          }
        ];
      };

      nixosConfigurations.NixOS = nixpkgs.lib.nixosSystem {
        # WHY: same pinned set and unfree policy as the Darwin host.
        pkgs = pkgsLinux;
        specialArgs = {
          hostName = "NixOS";
          inherit username repoRoot;
          users = usersNixOS;
          nucleusApps = nucleusAppsLinux // {
            nucleus-service-watchdog = serviceWatchdogPkgLinux;
          };
          treefmtPackage = mkTreefmtWrapper systems.linux pkgsLinux;
        };
        system = systems.linux;
        modules = [
          ./hosts/NixOS/default.nix
          sops-nix.nixosModules.sops
          ./modules/env/env-secrets-sops.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.backupFileExtension = "bak";

            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = {
              hostName = "NixOS";
              inherit nixpkgs username repoRoot;
              users = usersNixOS;
              hermes-agent = hermes-agent;
              nucleusApps = nucleusAppsLinux // {
                nucleus-service-watchdog = serviceWatchdogPkgLinux;
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
        // nucleusAppsMac
        // {
          flakeInputs = mkFlakeInputsPkg pkgsMac flakeInputsMac;
        };
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
        // nucleusAppsLinux
        // {
          flakeInputs = mkFlakeInputsPkg pkgsLinux flakeInputsLinux;
        };
      };

      # Committed as src/hosts/Windows/system/winget-packages.json and read by
      # apply.ps1, since Windows does not evaluate Nix.
      winget-packages = pkgsMac.writeText "winget-packages.json" (
        let
          evaluated = nixpkgs.lib.evalModules {
            prefix = [ ];
            modules = [
              ./modules/core.nix
              {
                # core.nix reads this for macOS backend selection; unused in this eval.
                nucleus.packages.selection.backend = "policy";
              }
              # core.nix sets `assertions`, normally provided by NixOS/nix-darwin.
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
              # core.nix resolves the host from the `hostName` module arg.
              hostName = "Windows";
            };
          };
        in
        (import ./modules/lib/json.nix { lib = nixpkgs.lib; }).toSortedJSON {
          "$schema" = "./winget-packages.schema.json";
          packages = evaluated.config.nucleus.windows.wingetPackages.packages;
        }
      );

      devShells = {
        "${systems.mac}" = {
          default =
            let
              # WHY: rust-overlay pins the toolchain so the devShell stays reproducible.
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
              # WHY: the macOS linker needs -liconv; glibc ships it on Linux.
              buildInputs = [ pkgsDevMac.libiconv ];
              # WHY: CMake projects use CMAKE_C_COMPILER_LAUNCHER from env-secrets.
              CC = "${pkgsDevMac.sccache}/bin/sccache ${pkgsDevMac.llvmPackages.clang}/bin/clang";
              CXX = "${pkgsDevMac.sccache}/bin/sccache ${pkgsDevMac.llvmPackages.clang}/bin/clang++";
              # WHY: `nix print-dev-env` does not inherit the parent shell's
              # variables, so print-dev-env must emit EDITOR/VISUAL itself.
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
              # WHY: CMake projects use CMAKE_C_COMPILER_LAUNCHER from env-secrets.
              CC = "${pkgsDevLinux.sccache}/bin/sccache ${pkgsDevLinux.llvmPackages.clang}/bin/clang";
              CXX = "${pkgsDevLinux.sccache}/bin/sccache ${pkgsDevLinux.llvmPackages.clang}/bin/clang++";
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

      homeConfigurations.${username} = home-manager.lib.homeManagerConfiguration {
        extraSpecialArgs = {
          hostName = "NixOS";
          inherit
            nixpkgs
            username
            repoRoot
            hermes-agent
            ;
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
