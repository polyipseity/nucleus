{
  description = "Nucleus - Unified Declarative System Configuration";

  # ---------------------------------------------------------------------------
  # Inputs — pinned external flakes.
  # All sub-inputs are pointed at the single shared nixpkgs to avoid pulling in
  # multiple versions of the same package set.
  # ---------------------------------------------------------------------------
  inputs = {
    # nix-darwin: NixOS-style declarative configuration for macOS.
    darwin = {
      url = "github:lnl7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # home-manager: user-environment management; used on all three host types.
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # nixpkgs: the single shared package set; pinned to nixos-unstable for
    # access to recent packages on both NixOS and Darwin.
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    # sops-nix: integrates SOPS secret decryption into NixOS / nix-darwin /
    # Home Manager activation without ever writing secrets to the Nix store.
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { darwin, home-manager, nixpkgs, sops-nix, ... }:
    let
      # Shared user account name propagated to every host via specialArgs.
      username = "polyipseity";

      # Canonical system strings for the two supported architectures.
      systems = {
        linux = "x86_64-linux";
        mac = "aarch64-darwin";
      };

      # Build a nixpkgs package set for a given system with unfree packages
      # permitted (required for VS Code, Discord, Spotify, etc.).
      mkPkgs = system: import nixpkgs {
        inherit system;
        config.allowUnfree = true;

        overlays = [
          (_final: prev: {
            # Disable chromaprint test suite to prevent OOM kills during build.
            # The tests (FFmpegAudioReaderTest) are memory-intensive and get
            # SIGKILL'd in the Nix sandbox's memory constraints on Apple Silicon.
            # The resulting binary is unaffected; this suppresses an unreliable
            # test that does not gate correct chromaprint operation in practice.
            chromaprint = prev.chromaprint.overrideAttrs (_: { doCheck = false; });
          })
          (_final: prev:
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
            in {
              gnupg = gnupg25_pinned;
              gnupg24 = gnupg25_pinned;
            })
        ];
      };

      pkgsLinux = mkPkgs systems.linux;
      pkgsMac   = mkPkgs systems.mac;

      # Build the `nix run .#apply` app for a given package set.
      # Wraps scripts/apply.sh in a shell application that has git, openssh,
      # sops, and ssh-to-age on PATH so the machine age key auto-registration
      # step can derive the age public key and rewrap all SOPS-encrypted files.
      # openssh provides ssh-keygen for the generate_ssh_host_key_if_needed step
      # that creates /etc/ssh/ssh_host_ed25519_key on first-provision machines.
      mkApplyApp = pkgs: {
        type = "app";
        program = "${pkgs.writeShellApplication {
          name = "nucleus-apply";
          runtimeInputs = [
            pkgs.git
            pkgs.openssh
            pkgs.sops
            pkgs.ssh-to-age
          ];
          text = builtins.readFile ./scripts/apply.sh;
        }}/bin/nucleus-apply";
      };

      # Build the PowerShell syntax validation app for a given package set.
      # Runtime dependencies are bundled from this flake so CI and local runs do
      # not depend on ad-hoc system package versions.
      mkPowerShellSyntaxValidationApp = pkgs: {
        type = "app";
        program = "${pkgs.writeShellApplication {
          name = "nucleus-validate-powershell-syntax";
          runtimeInputs = [
            pkgs.git
            pkgs.powershell
          ];
          text = ''
            exec pwsh -NoLogo -NoProfile -NonInteractive -File "${../scripts/validate-powershell-syntax.ps1}" "$@"
          '';
        }}/bin/nucleus-validate-powershell-syntax";
      };

      # Build the shell script lint app for a given package set.
      # Runtime dependencies are bundled from this flake so CI and local runs do
      # not depend on host-global shellcheck/git installations.
      mkShellScriptValidationApp = pkgs: {
        type = "app";
        program = "${pkgs.writeShellApplication {
          name = "nucleus-validate-shell-scripts";
          runtimeInputs = [
            pkgs.git
            pkgs.shellcheck
          ];
          text = ''
            exec sh "${../scripts/validate-shell-scripts.sh}" "$@"
          '';
        }}/bin/nucleus-validate-shell-scripts";
      };

      # Build pre-flight health checks as a runnable app that fails fast before
      # apply/bootstrap flows attempt large downloads or secret-dependent work.
      mkHealthCheckApp = pkgs: {
        type = "app";
        program = "${pkgs.writeShellApplication {
          name = "nucleus-health-check";
          runtimeInputs = [
            pkgs.curl
            pkgs.git
            pkgs.gnupg
            pkgs.sops
          ];
          text = builtins.readFile ../scripts/health-check.sh;
        }}/bin/nucleus-health-check";
      };

      # Build a cross-host update orchestration app.
      # It updates flake inputs, optionally upgrades Windows packages, and then
      # rewraps SOPS files for all declared recipients in one bounded workflow.
      mkUpdateApp = pkgs: {
        type = "app";
        program = "${pkgs.writeShellApplication {
          name = "nucleus-update";
          runtimeInputs = [
            pkgs.gnupg
            pkgs.nix
            pkgs.sops
          ];
          text = builtins.readFile ../scripts/update.sh;
        }}/bin/nucleus-update";
      };

      # Build garbage-collection app for POSIX hosts.
      # This combines Nix store GC and stale wallpaper cleanup in one bounded
      # operation without touching unmanaged user content outside declarative
      # scopes.
      mkGcApp = pkgs: {
        type = "app";
        program = "${pkgs.writeShellApplication {
          name = "nucleus-gc";
          runtimeInputs = [
            pkgs.gnugrep
          ];
          text = builtins.readFile ../scripts/gc.sh;
        }}/bin/nucleus-gc";
      };

    in {
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
          apply = mkApplyApp pkgsMac;
          darwin-rebuild = {
            type = "app";
            program = "${darwin.packages.${systems.mac}.darwin-rebuild}/bin/darwin-rebuild";
          };
          validate-shell-scripts = mkShellScriptValidationApp pkgsMac;
          validate-powershell-syntax = mkPowerShellSyntaxValidationApp pkgsMac;
          gc = mkGcApp pkgsMac;
          health-check = mkHealthCheckApp pkgsMac;
          update = mkUpdateApp pkgsMac;
        };
        "${systems.linux}" = {
          apply = mkApplyApp pkgsLinux;
          home-manager = {
            type = "app";
            program = "${home-manager.packages.${systems.linux}.home-manager}/bin/home-manager";
          };
          nixos-rebuild = {
            type = "app";
            program = "${pkgsLinux.nixos-rebuild}/bin/nixos-rebuild";
          };
          validate-shell-scripts = mkShellScriptValidationApp pkgsLinux;
          validate-powershell-syntax = mkPowerShellSyntaxValidationApp pkgsLinux;
          gc = mkGcApp pkgsLinux;
          health-check = mkHealthCheckApp pkgsLinux;
          update = mkUpdateApp pkgsLinux;
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
        specialArgs = { inherit username; };
        system = systems.mac;
        modules = [
          ./hosts/macbook/default.nix
          sops-nix.darwinModules.sops
          home-manager.darwinModules.home-manager
          {
            # Preserve pre-existing dotfiles on first activation instead of
            # aborting when Home Manager would overwrite them.
            home-manager.backupFileExtension = "hm-backup";

            # Share the system nixpkgs instance to avoid a duplicate evaluation.
            home-manager.useGlobalPkgs = true;
            # Install user packages into the user profile rather than /etc.
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = { inherit username; };
            home-manager.users.${username} = {
              imports = [
                sops-nix.homeManagerModules.sops
                ./modules/home.nix
              ];
            };
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
        specialArgs = { inherit username; };
        system = systems.linux;
        modules = [
          ./hosts/nixos/default.nix
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          {
            # Mirror the Darwin behavior so first switch is non-destructive when
            # user-owned files already exist at Home Manager target paths.
            home-manager.backupFileExtension = "hm-backup";

            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = { inherit username; };
            home-manager.users.${username} = {
              imports = [
                sops-nix.homeManagerModules.sops
                ./modules/home.nix
              ];
            };
          }
        ];
      };

      # -----------------------------------------------------------------------
      # packages — installable via `nix profile add .#bootstrap-deps`.
      # bootstrap-deps is a symlink-joined set of the tools used for manual
      # secret lifecycle tasks during bootstrap (gnupg, sops, ssh-to-age).
      # -----------------------------------------------------------------------
      packages = {
        "${systems.mac}".bootstrap-deps = pkgsMac.symlinkJoin {
          name = "bootstrap-deps";
          paths = [
            pkgsMac.gnupg
            pkgsMac.sops
            pkgsMac.ssh-to-age
          ];
        };
        "${systems.linux}".bootstrap-deps = pkgsLinux.symlinkJoin {
          name = "bootstrap-deps";
          paths = [
            pkgsLinux.gnupg
            pkgsLinux.sops
            pkgsLinux.ssh-to-age
          ];
        };
      };

      # -----------------------------------------------------------------------
      # devShells — entered via `nix develop .#bootstrap`.
      # Provides the same bootstrap tool set as bootstrap-deps but as an
      # interactive shell environment for manual troubleshooting.
      # -----------------------------------------------------------------------
      devShells = {
        "${systems.mac}".bootstrap = pkgsMac.mkShell {
          packages = [
            pkgsMac.gnupg
            pkgsMac.sops
            pkgsMac.ssh-to-age
          ];
        };
        "${systems.linux}".bootstrap = pkgsLinux.mkShell {
          packages = [
            pkgsLinux.gnupg
            pkgsLinux.sops
            pkgsLinux.ssh-to-age
          ];
        };
      };

      # -----------------------------------------------------------------------
      # homeConfigurations — standalone Home Manager profile.
      # Used on plain Linux and WSL where neither NixOS nor nix-darwin manages
      # the system layer.  Evaluated against the Linux package set so the same
      # profile can be applied to WSL (which is x86_64-linux) without changes.
      # -----------------------------------------------------------------------
      homeConfigurations.${username} = home-manager.lib.homeManagerConfiguration {
        extraSpecialArgs = { inherit username; };
        modules = [
          sops-nix.homeManagerModules.sops
          ./modules/home.nix
        ];
        pkgs = pkgsLinux;
      };
    };
}
