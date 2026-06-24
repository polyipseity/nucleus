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
    scripts = {
      url = "path:../scripts";
      flake = false;
    };
  };

  outputs =
    {
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
      scripts,
      smudge-smudge,
      sops-nix,
      macos-fuse-t-cask,
      zackelia-formulae,
      ...
    }:
    let
      # Loaded from src/modules/users.json, mirroring the Windows pattern.
      users = builtins.fromJSON (builtins.readFile ./modules/users.json);

      # Filter users by isPrimary=true and extract the attr name.
      username = builtins.head (
        builtins.filter (name: users.${name}.isPrimary) (builtins.attrNames users)
      );

      # home-manager.users attrset: each user gets home.nix; primary also gets sops-nix.
      mkHomeManagerUsers =
        userModulesPath:
        builtins.mapAttrs (name: user: {
          imports = [
            {
              _module.args = {
                inherit users;
                managedUser = user;
                managedUsername = name;
              };
            }
            userModulesPath
          ]
          ++ (builtins.filter (m: m != null) [
            (if user.isPrimary then sops-nix.homeManagerModules.sops else null)
          ]);
        }) users;

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
              # a2a-sdk tests are flaky (timing/FastAPI e2e errors in Nix sandbox).
              # overrideScope is used because python3.override doesn't propagate
              # through the fixpoint in overlay context.
              python3Packages = prev.python3Packages.overrideScope (
                _pyfinal: pyprev: {
                  a2a-sdk = pyprev.a2a-sdk.overrideAttrs (_: {
                    dontUsePytestCheck = true;
                  });
                }
              );
              # Codec libs that are ffmpeg-full deps: tests OOM on aarch64-darwin
              # Nix sandbox; ffmpeg-full's tests cover them.
              chromaprint = prev.chromaprint.overrideAttrs (_: {
                doCheck = false;
              });
              davs2 = prev.davs2.overrideAttrs (_: {
                doCheck = false;
              });
              kvazaar = prev.kvazaar.overrideAttrs (_: {
                doCheck = false;
              });
              lcevcdec = prev.lcevcdec.overrideAttrs (_: {
                doCheck = false;
              });
              openapv = prev.openapv.overrideAttrs (_: {
                doCheck = false;
              });
              openh264 = prev.openh264.overrideAttrs (_: {
                doCheck = false;
              });
              svt-av1 = prev.svt-av1.overrideAttrs (_: {
                doCheck = false;
              });
              uavs3d = prev.uavs3d.overrideAttrs (_: {
                doCheck = false;
              });
              vvenc = prev.vvenc.overrideAttrs (_: {
                doCheck = false;
              });
              xavs2 = prev.xavs2.overrideAttrs (_: {
                doCheck = false;
              });
              xeve = prev.xeve.overrideAttrs (_: {
                doCheck = false;
              });
              xevd = prev.xevd.overrideAttrs (_: {
                doCheck = false;
              });
              # On macOS, koffi/build/koffi is a native binary, not a
              # directory, so the unguarded
              # `find "$nm/koffi/build/koffi" ...` in upstream postInstall
              # fails with "No such file or directory".
              pi-coding-agent = prev.pi-coding-agent.overrideAttrs (old: {
                postInstall =
                  builtins.replaceStrings
                    [ "find \"$nm/koffi/build/koffi\"" ]
                    [ "[ -d \"$nm/koffi/build/koffi\" ] && find \"$nm/koffi/build/koffi\"" ]
                    old.postInstall;
              });
            })
            (_final: prev: {
              # ollama's cmake/local.cmake calls ollama_check_metal_toolchain()
              # unconditionally on Apple Silicon when OLLAMA_MLX_BACKENDS is not
              # pre-defined. That check runs `xcrun -sdk macosx metal`, which
              # fails during nix builds because DEVELOPER_DIR points at the Nix
              # apple SDK instead of real Xcode. Pre-empt the check by defining
              # OLLAMA_MLX_BACKENDS early so cmake skips the Metal probe.
              # Upstream fix from
              # https://github.com/NixOS/nixpkgs/pull/529076.
              # (PR closed, not merged — still required at this pin)
              ollama = prev.ollama.overrideAttrs (old: {
                postPatch = (old.postPatch or "") + ''
                  substituteInPlace cmake/local.cmake \
                    --replace-fail \
                      "ollama_default_mlx_backends(_ollama_default_mlx_backends)" \
                      "set(_ollama_default_mlx_backends \"\")"
                '';
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
                  if prev.stdenv.isDarwin then
                    if prev.stdenv.isAarch64 then
                      prev.fetchurl {
                        url = "https://github.com/HEnquist/camillagui-backend/releases/download/v${version}/bundle_macos_aarch64.tar.gz";
                        hash = "sha256-CdoLZUrvqhyYPwIIUk2av3aOihOuRnDWm8ZcF/1LT2M=";
                      }
                    else
                      prev.fetchurl {
                        url = "https://github.com/HEnquist/camillagui-backend/releases/download/v${version}/bundle_macos_intel.tar.gz";
                        hash = "sha256-RUDHi8Bbhpdydr6lGI+TCNTMqtlUyoJgtH0rG2x01kE=";
                      }
                  else if prev.stdenv.isAarch64 then
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

      # writeShellApplication plus lib.sh bundling, so scripts that source
      # lib.sh work in both repo-direct and nix-store contexts.
      writeShellApplicationWithLib =
        pkgs: args:
        let
          name = args.name;
          baseDrv = pkgs.writeShellApplication (builtins.removeAttrs args [ "extraBin" ]);
          extraBin = args.extraBin or { };
          libShDrv = pkgs.runCommand "${name}-lib-sh" { } ''
            mkdir -p "$out/bin" "$out/src/scripts"
            cp "${./scripts/lib.sh}" "$out/src/scripts/lib.sh"
            chmod +x "$out/src/scripts/lib.sh"
            ln -s ../src/scripts/lib.sh "$out/bin/lib.sh"
            ${pkgs.lib.concatStringsSep "\n" (
              pkgs.lib.mapAttrsToList (target: src: ''
                mkdir -p "$(dirname "$out/bin/${target}")"
                cp "${src}" "$out/bin/${target}"
              '') extraBin
            )}
          '';
        in
        pkgs.symlinkJoin {
          name = "${name}-with-lib";
          paths = [
            baseDrv
            libShDrv
          ];
        };

      # Helper for `nix run .#<name>` apps. Wraps writeShellApplicationWithLib.
      # Defaults to ../scripts/${name}.sh.
      mkApp =
        pkgs:
        {
          name,
          runtimeInputs,
          extraBin ? { },
          script ? scripts + "/${name}.sh",
        }:
        let
          appName = "nucleus-${name}";
        in
        {
          type = "app";
          program = "${
            writeShellApplicationWithLib pkgs {
              name = appName;
              runtimeInputs = runtimeInputs;
              text = builtins.readFile script;
              inherit extraBin;
            }
          }/bin/${appName}";
        };

      # `nix run .#apply` — wraps src/scripts/apply.sh with git/jq/openssh/prek/
      # sops/ssh-to-age on PATH. Sibling scripts bundled via symlinkJoin so
      # apply.sh resolves them through $_ash_script_dir.

      mkApplyApp =
        pkgs:
        let
          baseApply = writeShellApplicationWithLib pkgs {
            name = "nucleus-apply";
            runtimeInputs = [
              pkgs.curl
              pkgs.git
              pkgs.jq
              pkgs.openssh
              pkgs.prek
              pkgs.sops
              pkgs.ssh-to-age
            ];
            text = builtins.readFile ./scripts/apply.sh;
          };
          # Sibling scripts (generate-ssh-host-key.sh etc) bundled into bin/
          # so apply.sh resolves them through $_ash_script_dir. ai-sync and
          # vm-setup are writeShellApplication derivations so apply.sh can run
          # them from PATH with build-time runtimeInputs (jq).
          aiSyncDrv = writeShellApplicationWithLib pkgs {
            name = "nucleus-ai-sync";
            runtimeInputs = [ pkgs.jq ];
            text = builtins.readFile (scripts + "/ai-sync.sh");
          };
          vmSetupDrv = writeShellApplicationWithLib pkgs {
            name = "nucleus-vm-setup";
            runtimeInputs = [ pkgs.jq ];
            text = builtins.readFile (scripts + "/vm-setup.sh");
            extraBin = {
              "vm-setup/lib.sh" = scripts + "/vm-setup/lib.sh";
            };
          };
          siblingScripts = pkgs.runCommand "apply-siblings" { } ''
            mkdir -p "$out/bin"
            install -m755 "${./scripts/generate-ssh-host-key.sh}" "$out/bin/generate-ssh-host-key.sh"
            install -m755 "${./scripts/register-host-age-key.sh}" "$out/bin/register-host-age-key.sh"
            install -m755 "${./scripts/install-prek-hooks.sh}" "$out/bin/install-prek-hooks.sh"
            install -m755 "${aiSyncDrv}/bin/nucleus-ai-sync" "$out/bin/nucleus-ai-sync"
            install -m755 "${vmSetupDrv}/bin/nucleus-vm-setup" "$out/bin/nucleus-vm-setup"
          '';
          applyDrv = pkgs.symlinkJoin {
            name = "nucleus-apply";
            paths = [
              baseApply
              siblingScripts
            ];
          };
        in
        {
          type = "app";
          program = "${applyDrv}/bin/nucleus-apply";
        };

      # PowerShell syntax validation (bundled deps so CI doesn't need system packages).
      mkCheckPwshApp = pkgs: {
        type = "app";
        program = "${
          pkgs.writeShellApplication {
            name = "nucleus-check-pwsh";
            runtimeInputs = [
              pkgs.git
              pkgs.powershell
            ];
            text = ''
              exec pwsh -NoLogo -NoProfile -NonInteractive -File "${scripts + "/check-pwsh.ps1"}" "$@"
            '';
          }
        }/bin/nucleus-check-pwsh";
      };

      # ShellCheck-based shell script linting.
      mkCheckShApp =
        pkgs:
        mkApp pkgs {
          name = "check-sh";
          runtimeInputs = [
            pkgs.bash
            pkgs.git
            pkgs.shellcheck
          ];
        };

      # Packer template validation.
      mkCheckPackerApp =
        pkgs:
        mkApp pkgs {
          name = "check-packer";
          runtimeInputs = [
            pkgs.bash
            pkgs.packer
          ];
        };

      # Build the consolidated repository check app for a given package set.
      mkCheckApp =
        pkgs:
        mkApp pkgs {
          name = "check";
          runtimeInputs = [
            pkgs.bash
            pkgs.deadnix
            pkgs.git
            pkgs.jq
            pkgs.nixfmt
            pkgs.packer
            pkgs.powershell
            pkgs.yq-go
          ];
        };

      mkTestApp =
        pkgs:
        mkApp pkgs {
          name = "test";
          runtimeInputs = [
            pkgs.bash
            pkgs.findutils
            pkgs.git
            pkgs.powershell
            pkgs.shellcheck
          ];
        };

      # Build pre-flight health checks as a runnable app that fails fast before
      # apply/bootstrap flows attempt large downloads or secret-dependent work.
      mkHealthCheckApp =
        pkgs:
        mkApp pkgs {
          name = "health-check";
          runtimeInputs = [
            pkgs.curl
            pkgs.git
            pkgs.gnupg
            pkgs.sops
          ];
        };

      # Build a cross-host update orchestration app.
      # Intentionally does not inject nixpkgs `pkgs.nix` into PATH — update.sh
      # should use the host nix binary so host-specific nix.conf settings
      # (eval-cores, lazy-trees) are interpreted without warnings.
      mkUpdateApp =
        pkgs:
        mkApp pkgs {
          name = "update";
          runtimeInputs = [
            pkgs.gnupg
            pkgs.sops
          ];
        };

      # Build garbage-collection app for POSIX hosts.
      mkGcApp =
        pkgs:
        mkApp pkgs {
          name = "gc";
          runtimeInputs = [
            pkgs.jq
            pkgs.gnugrep
            pkgs.home-manager
          ];
        };

      # Build cloud setup helper app for POSIX hosts.
      mkCloudSetupApp =
        pkgs:
        mkApp pkgs {
          name = "cloud-setup";
          runtimeInputs = [
            pkgs.git
            pkgs.jq
            pkgs.rclone
          ];
        };

      # Build cloud replica sync helper app for POSIX hosts.
      mkReplicaSyncApp =
        pkgs:
        mkApp pkgs {
          name = "replica-sync";
          runtimeInputs = [
            pkgs.git
            pkgs.jq
            pkgs.rclone
          ];
        };

      # Build cloud replica state reset helper app for POSIX hosts.
      mkReplicaResetApp =
        pkgs:
        mkApp pkgs {
          name = "replica-reset";
          runtimeInputs = [
            pkgs.git
            pkgs.jq
          ];
        };

      # Build AI model sync app for POSIX hosts.
      mkAiSyncApp =
        pkgs:
        mkApp pkgs {
          name = "ai-sync";
          runtimeInputs = [ pkgs.jq ];
        };

      # Build VM setup app for POSIX hosts.
      mkVMSetupApp =
        pkgs:
        mkApp pkgs {
          name = "vm-setup";
          runtimeInputs = [ pkgs.jq ];
          extraBin = {
            "vm-setup/lib.sh" = scripts + "/vm-setup/lib.sh";
          };
        };

      mkBootstrapApp =
        pkgs:
        mkApp pkgs {
          name = "bootstrap";
          runtimeInputs = [ ];
          extraBin = {
            "bootstrap-versions.env" = scripts + "/bootstrap-versions.env";
          };
        };

      mkBumpLockfileApp =
        pkgs:
        mkApp pkgs {
          name = "bump-lockfile";
          runtimeInputs = [ pkgs.jq ];
        };

      # Build unified service management app for POSIX hosts.
      mkSvcApp =
        pkgs:
        mkApp pkgs {
          name = "svc";
          runtimeInputs = [ pkgs.jq ];
        };

      # Build the `nucleus logs` CLI viewer app for POSIX hosts.
      mkLogsApp =
        pkgs:
        mkApp pkgs {
          name = "logs";
          runtimeInputs = [ pkgs.jq ];
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
        "${systems.mac}" = {
          ai-sync = mkAiSyncApp pkgsMac;
          apply = mkApplyApp pkgsMac;
          bootstrap = mkBootstrapApp pkgsMac;
          bump-lockfile = mkBumpLockfileApp pkgsMac;
          check = mkCheckApp pkgsMac;
          test = mkTestApp pkgsMac;
          check-packer = mkCheckPackerApp pkgsMac;
          check-pwsh = mkCheckPwshApp pkgsMac;
          check-sh = mkCheckShApp pkgsMac;
          cloud-setup = mkCloudSetupApp pkgsMac;
          darwin-rebuild = {
            type = "app";
            program = "${darwin.packages.${systems.mac}.darwin-rebuild}/bin/darwin-rebuild";
          };
          gc = mkGcApp pkgsMac;
          health-check = mkHealthCheckApp pkgsMac;
          logs = mkLogsApp pkgsMac;
          nixos-generators = nixos-generators.apps.${systems.mac}.default;
          replica-reset = mkReplicaResetApp pkgsMac;
          replica-sync = mkReplicaSyncApp pkgsMac;
          update = mkUpdateApp pkgsMac;
          svc = mkSvcApp pkgsMac;
          vm-setup = mkVMSetupApp pkgsMac;
        };
        "${systems.linux}" = {
          ai-sync = mkAiSyncApp pkgsLinux;
          apply = mkApplyApp pkgsLinux;
          bootstrap = mkBootstrapApp pkgsLinux;
          bump-lockfile = mkBumpLockfileApp pkgsLinux;
          check = mkCheckApp pkgsLinux;
          test = mkTestApp pkgsLinux;
          check-packer = mkCheckPackerApp pkgsLinux;
          check-pwsh = mkCheckPwshApp pkgsLinux;
          check-sh = mkCheckShApp pkgsLinux;
          cloud-setup = mkCloudSetupApp pkgsLinux;
          gc = mkGcApp pkgsLinux;
          health-check = mkHealthCheckApp pkgsLinux;
          logs = mkLogsApp pkgsLinux;
          home-manager = {
            type = "app";
            program = "${home-manager.packages.${systems.linux}.home-manager}/bin/home-manager";
          };
          nixos-rebuild = {
            type = "app";
            program = "${pkgsLinux.nixos-rebuild}/bin/nixos-rebuild";
          };
          nixos-generators = nixos-generators.apps.${systems.linux}.default;
          replica-reset = mkReplicaResetApp pkgsLinux;
          replica-sync = mkReplicaSyncApp pkgsLinux;
          update = mkUpdateApp pkgsLinux;
          svc = mkSvcApp pkgsLinux;
          vm-setup = mkVMSetupApp pkgsLinux;
        };
      };

      # -----------------------------------------------------------------------
      # darwinConfigurations — nix-darwin host for the MacBook.
      # Home Manager is embedded as a nix-darwin module so that the single
      # `darwin-rebuild switch` command activates both system and user config.
      # -----------------------------------------------------------------------
      darwinConfigurations.macbook = darwin.lib.darwinSystem {
        # Reuse the shared package set so allowUnfree policy from mkPkgs is
        # applied consistently to both system and embedded Home Manager evals.
        pkgs = pkgsMac;
        specialArgs = {
          inherit username users;
          inherit
            homebrew-core
            homebrew-cask
            cirruslabs-cli
            macos-fuse-t-cask
            smudge-smudge
            zackelia-formulae
            ;
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
            home-manager.backupFileExtension = "hm-backup";

            # Share the system nixpkgs instance to avoid a duplicate evaluation.
            home-manager.useGlobalPkgs = true;
            # Install user packages into the user profile rather than /etc.
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = {
              inherit nixpkgs username users;
              vsCodeMarketplace = vsCodeMarketplaceMac;
            };
            home-manager.users = mkHomeManagerUsers ./modules/home.nix;
          }
        ];
      };

      # -----------------------------------------------------------------------
      # nixosConfigurations — NixOS host for the generic Linux machine.
      # Same Home Manager embedding pattern as the Darwin host.
      # -----------------------------------------------------------------------
      nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
        # Keep NixOS evaluation aligned with the same pinned package set and
        # unfree policy used by the rest of the flake outputs.
        pkgs = pkgsLinux;
        specialArgs = { inherit username users; };
        system = systems.linux;
        modules = [
          ./hosts/NixOS/default.nix
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          {
            # Mirror the Darwin behavior so first switch is non-destructive when
            # user-owned files already exist at Home Manager target paths.
            home-manager.backupFileExtension = "hm-backup";

            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = {
              inherit nixpkgs username users;
              vsCodeMarketplace = vsCodeMarketplaceLinux;
            };
            home-manager.users = mkHomeManagerUsers ./modules/home.nix;
          }
        ];
      };

      # -----------------------------------------------------------------------
      # packages — installable via `nix profile add .#bootstrap-deps`.
      # bootstrap-deps is a symlink-joined set of the tools used for manual
      # secret lifecycle tasks during bootstrap (gnupg, sops, ssh-to-age).
      # -----------------------------------------------------------------------
      packages = {
        "${systems.mac}" = {
          nixfmt = pkgsMac.nixfmt;
          bootstrap-deps = pkgsMac.symlinkJoin {
            name = "bootstrap-deps";
            paths = [
              pkgsMac.gnupg
              pkgsMac.sops
              pkgsMac.ssh-to-age
            ];
          };
        };
        "${systems.linux}" = {
          nixfmt = pkgsLinux.nixfmt;
          bootstrap-deps = pkgsLinux.symlinkJoin {
            name = "bootstrap-deps";
            paths = [
              pkgsLinux.gnupg
              pkgsLinux.sops
              pkgsLinux.ssh-to-age
            ];
          };
        };
      };

      # -----------------------------------------------------------------------
      # devShells — entered via `nix develop .#<name>` or auto-loaded by
      # nix-direnv when an .envrc with `use flake` is present.
      #
      #   default   — general development tools: bun (JS runtime), uv (Python
      #               package manager), Rust toolchain via rust-overlay (reads
      #               rust-toolchain.toml when present in the project root;
      #               falls back to the latest stable default otherwise), prek
      #               (Git hook manager for repos that opt in via prek.toml).
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
                pkgsDevMac.bun
                pkgsDevMac.prek
                rustToolchain
                pkgsDevMac.uv
              ];
              # libiconv is required by the macOS linker when building Rust/C projects
              # (ld: library not found for -liconv). It is included in glibc on Linux
              # so no equivalent addition is needed in the Linux devShell.
              buildInputs = [ pkgsDevMac.libiconv ];
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
                pkgsDevLinux.bun
                pkgsDevLinux.prek
                rustToolchain
                pkgsDevLinux.uv
              ];
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
          hostManualFile = "src/hosts/NixOS/MANUAL.md";
          inherit nixpkgs username users;
          vsCodeMarketplace = vsCodeMarketplaceLinux;
        };
        modules = [
          {
            _module.args = {
              managedUsername = username;
              managedUser = users.${username};
            };
          }
          sops-nix.homeManagerModules.sops
          ./modules/home.nix
        ];
        pkgs = pkgsLinux;
      };
    };
}
