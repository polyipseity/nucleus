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
    # nix-vscode-extensions: provides Nix derivations for VS Code Marketplace
    # extensions not yet packaged in nixpkgs, enabling a fully declarative
    # extension baseline without CLI-based activation fallbacks.
    nix-vscode-extensions = {
      url = "github:nix-community/nix-vscode-extensions";
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

  outputs = { darwin, home-manager, nix-vscode-extensions, nixpkgs, sops-nix, ... }:
    let
      # User registry — defines all users managed by this configuration.
      # Each user has homeDirectory, shell (as string path), isPrimary flag, and optional
      # devRepos configuration.
      # The primary user receives secret materialization.
      # Shell paths are deferred to activation time via posix-user-shell.nix.
      users = {
        polyipseity = {
          homeDirectory = "/Users/polyipseity";
          isPrimary = true;
          # Per-user password-store root used by pass / QtPass / gopass.
          # `~` is expanded in modules/home.nix to the user's homeDirectory.
          passwordStore = {
            path = "~/dev/monorepo-private/self/passwords";
          };
          # Dev repository provisioning for this user.
          devRepos = {
            enable = true;
            gitHubUsername = "polyipseity";
            # Repository list: each entry specifies either a symlink or git URL.
            repositories = [
              {
                name = "nucleus";
                # Resolve this symlink from the live checkout path recorded by
                # apply.sh so ~/dev/nucleus points at the working tree rather
                # than an immutable Nix store snapshot.
                symlinkFromRepoRoot = true;
                target = "dev/nucleus";
              }
              {
                name = "monorepo";
                url = "git@github.com:polyipseity/monorepo.git";
                target = "dev/monorepo";
              }
              {
                name = "monorepo-private";
                url = "git@github.com:polyipseity/monorepo-private.git";
                target = "dev/monorepo-private";
              }
            ];
          };
        };
      };

      # Derive the primary username from the registry.
      # Filter users by isPrimary=true and extract the name (the attr key).
      username = builtins.head (
        builtins.filter (name: users.${name}.isPrimary)
        (builtins.attrNames users)
      );

      # Generate home-manager.users attrset from the user registry.
      # Each user gets the home.nix module and optionally sops-nix if isPrimary.
      mkHomeManagerUsers = userModulesPath: builtins.mapAttrs (name: user:
        {
          imports = [
            {
              _module.args = {
                managedUser = user;
                managedUsername = name;
              };
            }
            userModulesPath
          ] ++ (builtins.filter (m: m != null) [
            (if user.isPrimary then sops-nix.homeManagerModules.sops else null)
          ]);
        }
      ) users;

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
        # .NET 6 is intentionally pinned for EIDE/runtime compatibility across
        # hosts. Upstream marks it insecure because it is EOL; keep this
        # exception narrowly scoped to the exact runtime derivation.
        config.permittedInsecurePackages = [
          "dotnet-runtime-6.0.36"
        ];

        overlays = [
          (_final: prev: {
            # Disable test suites for codec libraries that are ffmpeg-full
            # dependencies.  Their tests invoke ffmpeg or run encoder workloads
            # that get SIGKILL'd (exit 137) in the Nix sandbox's memory
            # constraints on Apple Silicon.  These are all specialized or
            # regional-standard codecs (AVS2/3, HEVC/VVC variants, LCEVC, APV)
            # that are not present in the aarch64-darwin binary cache, so they
            # must be built from source.  Suppressing the test phase does not
            # affect codec correctness; the libraries themselves are exercised
            # end-to-end by the ffmpeg-full test suite.
            chromaprint = prev.chromaprint.overrideAttrs (_: { doCheck = false; });
            davs2       = prev.davs2.overrideAttrs       (_: { doCheck = false; });
            kvazaar     = prev.kvazaar.overrideAttrs     (_: { doCheck = false; });
            lcevcdec    = prev.lcevcdec.overrideAttrs    (_: { doCheck = false; });
            openapv     = prev.openapv.overrideAttrs     (_: { doCheck = false; });
            openh264    = prev.openh264.overrideAttrs    (_: { doCheck = false; });
            svt-av1     = prev.svt-av1.overrideAttrs     (_: { doCheck = false; });
            uavs3d      = prev.uavs3d.overrideAttrs      (_: { doCheck = false; });
            vvenc       = prev.vvenc.overrideAttrs       (_: { doCheck = false; });
            xavs2       = prev.xavs2.overrideAttrs       (_: { doCheck = false; });
            xeve        = prev.xeve.overrideAttrs        (_: { doCheck = false; });
            xevd        = prev.xevd.overrideAttrs        (_: { doCheck = false; });
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

      # Per-system VS Code Marketplace derivation sets from nix-vscode-extensions.
      # Used by editors.nix to build Nix derivations for the ~20 extensions that
      # are not yet packaged in nixpkgs, replacing CLI-based activation with
      # fully declarative Nix store derivations.
      vscodeMarketplaceMac   = nix-vscode-extensions.extensions.${systems.mac}.vscode-marketplace;
      vscodeMarketplaceLinux = nix-vscode-extensions.extensions.${systems.linux}.vscode-marketplace;

      # Build the `nix run .#apply` app for a given package set.
      # Wraps scripts/apply.sh in a shell application that has git, openssh,
      # prek, sops, and ssh-to-age on PATH so the machine age key
      # auto-registration step can derive the age public key and rewrap all
      # SOPS-encrypted files, and the apply flow can install repository-local
      # prek hooks on the first successful run.
      # openssh provides ssh-keygen for the generate_ssh_host_key_if_needed step
      # that creates /etc/ssh/ssh_host_ed25519_key on first-provision machines.
      mkApplyApp = pkgs: {
        type = "app";
        program = "${pkgs.writeShellApplication {
          name = "nucleus-apply";
          runtimeInputs = [
            pkgs.git
            pkgs.openssh
            pkgs.prek
            pkgs.sops
            pkgs.ssh-to-age
          ];
          text = builtins.readFile ./scripts/apply.sh;
        }}/bin/nucleus-apply";
      };

      # Build the PowerShell syntax validation app for a given package set.
      # Runtime dependencies are bundled from this flake so CI and local runs do
      # not depend on ad-hoc system package versions.
      mkCheckPwshApp = pkgs: {
        type = "app";
        program = "${pkgs.writeShellApplication {
          name = "nucleus-check-pwsh";
          runtimeInputs = [
            pkgs.git
            pkgs.powershell
          ];
          text = ''
            exec pwsh -NoLogo -NoProfile -NonInteractive -File "${../scripts/check-pwsh.ps1}" "$@"
          '';
        }}/bin/nucleus-check-pwsh";
      };

      # Build the shell script lint app for a given package set.
      # Runtime dependencies are bundled from this flake so CI and local runs do
      # not depend on host-global shellcheck/git installations.
      mkCheckShApp = pkgs: {
        type = "app";
        program = "${pkgs.writeShellApplication {
          name = "nucleus-check-sh";
          runtimeInputs = [
            pkgs.git
            pkgs.shellcheck
          ];
          text = ''
            exec sh "${../scripts/check-sh.sh}" "$@"
          '';
        }}/bin/nucleus-check-sh";
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
            pkgs.sops
          ];
          # Intentionally do not inject nixpkgs `pkgs.nix` into PATH here.
          # update.sh should use the host nix binary so host-specific nix.conf
          # settings (e.g. Determinate Nix keys like eval-cores/lazy-trees)
          # are interpreted by the matching implementation without warnings.
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
            pkgs.home-manager
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
          check-sh = mkCheckShApp pkgsMac;
          check-pwsh = mkCheckPwshApp pkgsMac;
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
          check-sh = mkCheckShApp pkgsLinux;
          check-pwsh = mkCheckPwshApp pkgsLinux;
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
        specialArgs = { inherit username users; };
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
            home-manager.extraSpecialArgs = {
              inherit nixpkgs username users;
              vscodeMarketplace = vscodeMarketplaceMac;
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
          ./hosts/nixos/default.nix
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
              vscodeMarketplace = vscodeMarketplaceLinux;
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
        extraSpecialArgs = {
          hostManualFile = "src/hosts/nixos/MANUAL.md";
          inherit nixpkgs username users;
          vscodeMarketplace = vscodeMarketplaceLinux;
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
