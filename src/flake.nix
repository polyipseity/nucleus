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
      # Strip $schema key — it's metadata for JSON Schema validators, not a user entry.
      users = builtins.removeAttrs (builtins.fromJSON (builtins.readFile ./modules/users.json)) [
        "$schema"
      ];

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
              # Nix sandbox; ffmpeg-full's tests cover them.
              davs2 = prev.davs2.overrideAttrs (_: {
                doCheck = !prev.stdenv.isDarwin;
              });
              kvazaar = prev.kvazaar.overrideAttrs (_: {
                doCheck = !prev.stdenv.isDarwin;
              });
              lcevcdec = prev.lcevcdec.overrideAttrs (_: {
                doCheck = !prev.stdenv.isDarwin;
              });
              openapv = prev.openapv.overrideAttrs (_: {
                doCheck = !prev.stdenv.isDarwin;
              });
              openh264 = prev.openh264.overrideAttrs (_: {
                doCheck = !prev.stdenv.isDarwin;
              });
              svt-av1 = prev.svt-av1.overrideAttrs (_: {
                doCheck = !prev.stdenv.isDarwin;
              });
              uavs3d = prev.uavs3d.overrideAttrs (_: {
                doCheck = !prev.stdenv.isDarwin;
              });
              vvenc = prev.vvenc.overrideAttrs (_: {
                doCheck = !prev.stdenv.isDarwin;
              });
              xavs2 = prev.xavs2.overrideAttrs (_: {
                doCheck = !prev.stdenv.isDarwin;
              });
              xeve = prev.xeve.overrideAttrs (_: {
                doCheck = !prev.stdenv.isDarwin;
              });
              xevd = prev.xevd.overrideAttrs (_: {
                doCheck = !prev.stdenv.isDarwin;
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
      # lib.sh work in both repo-direct and nix-store contexts regardless of
      # how $0 resolves through symlinks.
      writeShellApplicationWithLib =
        pkgs: args:
        let
          name = args.name;
          baseArgs = builtins.removeAttrs args [
            "extraBin"
            "excludeShellChecks"
            "extraShellCheckFlags"
            "sourcedFiles"
          ];
          baseDrv = pkgs.writeShellApplication (baseArgs // { checkPhase = "true"; });
          extraBin = args.extraBin or { };
          excludeShellChecks = args.excludeShellChecks or [ ];
          extraShellCheckFlags = args.extraShellCheckFlags or [ ];
          sourcedFiles = args.sourcedFiles or { };
          shellcheckArgs =
            pkgs.lib.optionals (excludeShellChecks != [ ]) [
              "--exclude"
              (pkgs.lib.concatStringsSep "," excludeShellChecks)
            ]
            ++ extraShellCheckFlags;
        in
        pkgs.runCommand "${name}-with-lib" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
          mkdir -p "$out/bin" "$out/src/scripts"
          cp -r "${baseDrv}/bin/." "$out/bin/"
          chmod +w "$out/bin/${name}"
          cp "${./scripts/lib/lib.sh}" "$out/src/scripts/lib/lib.sh"
          chmod +x "$out/src/scripts/lib/lib.sh"
          ln -s ../src/scripts/lib/lib.sh "$out/bin/lib.sh"
          ${pkgs.lib.concatStringsSep "\n" (
            pkgs.lib.mapAttrsToList (target: src: ''
              mkdir -p "$(dirname "$out/bin/${target}")"
              cp "${src}" "$out/bin/${target}"
            '') extraBin
          )}
          ${pkgs.lib.concatStringsSep "\n" (
            pkgs.lib.mapAttrsToList (target: src: ''
              cp "${src}" "$out/src/scripts/${target}"
              chmod +x "$out/src/scripts/${target}"
            '') sourcedFiles
          )}
          shellcheck ${pkgs.lib.escapeShellArgs shellcheckArgs} -x --source-path="$out/bin" "$out/bin/${name}"
        '';

      # Like mkApp but returns the derivation directly (no { type, program } wrapper).
      # Use for home.packages installation without nix run overhead.
      mkNucleusPackage =
        pkgs:
        {
          name,
          runtimeInputs,
          extraBin ? { },
          script ? scripts + "/${name}.sh",
          excludeShellChecks ? [ ],
          extraShellCheckFlags ? [ ],
          sourcedFiles ? { },
        }:
        assert pkgs.lib.assertMsg (builtins.baseNameOf script != "nucleus-${name}.sh") ''
          script filename '${builtins.baseNameOf script}' for package '${name}' must not start with 'nucleus-'.
          The nucleus- prefix is added automatically by the package derivation.
          Name the script file '${name}.sh' instead.
        '';
        writeShellApplicationWithLib pkgs {
          name = "nucleus-${name}";
          runtimeInputs = runtimeInputs;
          text = builtins.readFile script;
          inherit
            extraBin
            excludeShellChecks
            extraShellCheckFlags
            sourcedFiles
            ;
        };

      # Helper for `nix run .#<name>` apps. Delegates to mkNucleusPackage.
      # Defaults to ../scripts/${name}.sh.
      mkApp =
        pkgs: args:
        let
          pkg = mkNucleusPackage pkgs args;
        in
        {
          type = "app";
          program = "${pkg}/bin/nucleus-${args.name}";
        };

      # Derivation for nucleus-apply. Sibling scripts bundled via symlinkJoin so
      # apply.sh resolves them through $_ash_script_dir. ai-sync and vm-setup
      # are not bundled here — they are installed on PATH via home.packages
      # (see mkNucleusApps) and thus available in post-apply after rebuild.
      mkApplyPackage =
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
          siblingScripts = pkgs.runCommand "apply-siblings" { } ''
            mkdir -p "$out/bin"
            install -m755 "${./scripts/secrets/generate-ssh-host-key.sh}" "$out/bin/generate-ssh-host-key.sh"
            install -m755 "${./scripts/secrets/register-host-age-key.sh}" "$out/bin/register-host-age-key.sh"
            install -m755 "${./scripts/install-prek-hooks.sh}" "$out/bin/install-prek-hooks.sh"
          '';
        in
        pkgs.symlinkJoin {
          name = "nucleus-apply";
          paths = [
            baseApply
            siblingScripts
          ];
        };

      # App wrapper for `nix run .#apply`.
      mkApplyApp = pkgs: {
        type = "app";
        program = "${mkApplyPackage pkgs}/bin/nucleus-apply";
      };

      # PowerShell syntax validation (bundled deps so CI doesn't need system packages).
      mkCheckPwshPackage =
        pkgs:
        pkgs.writeShellApplication {
          name = "nucleus-check-pwsh";
          runtimeInputs = [
            pkgs.git
            pkgs.powershell
          ];
          text = ''
            exec pwsh -NoLogo -NoProfile -NonInteractive -File "${scripts + "/check-pwsh.ps1"}" "$@"
          '';
        };

      mkCheckPwshApp = pkgs: {
        type = "app";
        program = "${mkCheckPwshPackage pkgs}/bin/nucleus-check-pwsh";
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
      # Does NOT inject nixpkgs `pkgs.nix` into PATH — scripts/check.sh uses
      # nix eval which should use the host nix binary so host-specific nix.conf
      # settings (eval-cores, lazy-trees) are interpreted without warnings.
      mkCheckApp =
        pkgs:
        mkApp pkgs {
          name = "check";
          runtimeInputs = [
            pkgs.bash
            pkgs.deadnix
            pkgs.git
            pkgs.jq
            pkgs.nixf
            pkgs.nixfmt
            pkgs.packer
            pkgs.powershell
            pkgs.yq-go
          ];
          # SC2016: false positive — $schema in yq expressions is intentional.
          excludeShellChecks = [ "SC2016" ];
        };

      # Does NOT inject nixpkgs `pkgs.nix` into PATH — scripts/test.sh uses
      # nix-instantiate --eval which should use the host nix binary so
      # host-specific nix.conf settings (eval-cores, lazy-trees) are
      # interpreted without warnings.
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
      # Does NOT inject nixpkgs `pkgs.nix` into PATH — scripts/cloud-setup.sh
      # uses nix --option which should use the host nix binary so host-specific
      # nix.conf settings (eval-cores, lazy-trees) are interpreted without warnings.
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

      # Manage runtime configuration for nucleus services.
      mkNucleusConfigApp =
        pkgs:
        mkApp pkgs {
          name = "config";
          runtimeInputs = [ pkgs.jq ];
        };

      # Build the full set of nucleus app packages for a given package set.
      # Used by home-manager (home.packages) and flake packages output.
      mkNucleusApps = pkgs: {
        nucleus-apply = mkApplyPackage pkgs;
        nucleus-ai-sync = mkNucleusPackage pkgs {
          name = "ai-sync";
          runtimeInputs = [ pkgs.jq ];
        };
        nucleus-bootstrap = mkNucleusPackage pkgs {
          name = "bootstrap";
          runtimeInputs = [ ];
          extraBin = {
            "bootstrap-versions.env" = scripts + "/bootstrap-versions.env";
          };
        };
        nucleus-bump-lockfile = mkNucleusPackage pkgs {
          name = "bump-lockfile";
          runtimeInputs = [ pkgs.jq ];
        };
        nucleus-check = mkNucleusPackage pkgs {
          name = "check";
          runtimeInputs = [
            pkgs.bash
            pkgs.deadnix
            pkgs.git
            pkgs.jq
            pkgs.nixf
            pkgs.nixfmt
            pkgs.packer
            pkgs.powershell
            pkgs.check-jsonschema
            pkgs.yamllint
            pkgs.yq-go
          ];
          # SC2016: false positive — $schema in yq expressions is intentional.
          excludeShellChecks = [ "SC2016" ];
        };
        nucleus-check-packer = mkNucleusPackage pkgs {
          name = "check-packer";
          runtimeInputs = [
            pkgs.bash
            pkgs.packer
          ];
        };
        nucleus-check-pwsh = mkCheckPwshPackage pkgs;
        nucleus-check-sh = mkNucleusPackage pkgs {
          name = "check-sh";
          runtimeInputs = [
            pkgs.bash
            pkgs.git
            pkgs.shellcheck
          ];
        };
        nucleus-cleanup-nix = mkNucleusPackage pkgs {
          name = "cleanup-nix";
          runtimeInputs = [ pkgs.bash ];
          sourcedFiles = {
            "cleanup-nix-build-artifacts.sh" = ./scripts/cleanup-nix-build-artifacts.sh;
          };
        };
        nucleus-cloud-setup = mkNucleusPackage pkgs {
          name = "cloud-setup";
          runtimeInputs = [
            pkgs.git
            pkgs.jq
            pkgs.rclone
          ];
        };
        nucleus-config = mkNucleusPackage pkgs {
          name = "config";
          runtimeInputs = [ pkgs.jq ];
        };
        nucleus-gs-pdf-opt = mkNucleusPackage pkgs {
          name = "gs-pdf-opt";
          runtimeInputs = [ pkgs.ghostscript ];
        };
        nucleus-gc = mkNucleusPackage pkgs {
          name = "gc";
          runtimeInputs = [
            pkgs.jq
            pkgs.gnugrep
            pkgs.home-manager
          ];
        };
        nucleus-health-check = mkNucleusPackage pkgs {
          name = "health-check";
          runtimeInputs = [
            pkgs.curl
            pkgs.git
            pkgs.gnupg
            pkgs.sops
          ];
        };
        nucleus-replica-reset = mkNucleusPackage pkgs {
          name = "replica-reset";
          runtimeInputs = [
            pkgs.git
            pkgs.jq
          ];
        };
        nucleus-replica-sync = mkNucleusPackage pkgs {
          name = "replica-sync";
          runtimeInputs = [
            pkgs.git
            pkgs.jq
            pkgs.rclone
          ];
        };
        nucleus-svc = mkNucleusPackage pkgs {
          name = "svc";
          runtimeInputs = [ pkgs.jq ];
        };
        nucleus-service-watchdog = mkNucleusPackage pkgs {
          name = "service-watchdog";
          runtimeInputs = [ pkgs.jq ];
        };
        nucleus-test = mkNucleusPackage pkgs {
          name = "test";
          runtimeInputs = [
            pkgs.bash
            pkgs.findutils
            pkgs.git
            pkgs.powershell
            pkgs.shellcheck
          ];
        };
        nucleus-update = mkNucleusPackage pkgs {
          name = "update";
          runtimeInputs = [
            pkgs.gnupg
            pkgs.sops
          ];
        };
        nucleus-vm-setup = mkNucleusPackage pkgs {
          name = "vm-setup";
          runtimeInputs = [ pkgs.jq ];
          extraBin = {
            "vm-setup/lib.sh" = scripts + "/vm-setup/lib.sh";
          };
        };
      };

      nucleusAppsMac = mkNucleusApps pkgsMac;
      nucleusAppsLinux = mkNucleusApps pkgsLinux;

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
          nixos-generators = nixos-generators.apps.${systems.mac}.default;
          config = mkNucleusConfigApp pkgsMac;
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
          home-manager = {
            type = "app";
            program = "${home-manager.packages.${systems.linux}.home-manager}/bin/home-manager";
          };
          nixos-rebuild = {
            type = "app";
            program = "${pkgsLinux.nixos-rebuild}/bin/nixos-rebuild";
          };
          nixos-generators = nixos-generators.apps.${systems.linux}.default;
          config = mkNucleusConfigApp pkgsLinux;
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
          nucleusApps = nucleusAppsMac;
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
              nucleusApps = nucleusAppsMac;
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
        specialArgs = {
          inherit username users;
          nucleusApps = nucleusAppsLinux;
        };
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
              nucleusApps = nucleusAppsLinux;
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
        }
        // nucleusAppsMac;
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
        }
        // nucleusAppsLinux;
      };

      # -----------------------------------------------------------------------
      # devShells — entered via `nix develop .#<name>` or auto-loaded by
      # nix-direnv when an .envrc with `use flake` is present.
      #
      #   default   — general development tools: bun (JS runtime), uv (Python
      #               package manager), Rust toolchain via rust-overlay (reads
      #               rust-toolchain.toml when present in the project root;
      #               falls back to the latest stable default otherwise), prek
      #               (Git hook manager for repos that opt in via prek.toml),
      #               nixfmt (Nix formatter), powershell (pwsh) for pre-commit
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
                pkgsDevMac.bun
                pkgsDevMac.nixfmt
                pkgsDevMac.packer
                pkgsDevMac.powershell
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
                pkgsDevLinux.nixfmt
                pkgsDevLinux.packer
                pkgsDevLinux.powershell
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
