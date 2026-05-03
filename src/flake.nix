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
      };

      pkgsLinux = mkPkgs systems.linux;
      pkgsMac   = mkPkgs systems.mac;

      # Build the `nix run .#apply` app for a given package set.
      # Wraps scripts/apply.sh in a shell application that has git, gnupg, jq,
      # and sops on PATH, so the script needs no external dependencies at
      # runtime beyond a working Nix installation.
      mkApplyApp = pkgs: {
        type = "app";
        program = "${pkgs.writeShellApplication {
          name = "nucleus-apply";
          runtimeInputs = [ pkgs.git pkgs.gnupg pkgs.jq pkgs.sops ];
          text = builtins.readFile ./scripts/apply.sh;
        }}/bin/nucleus-apply";
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
        };
      };

      # -----------------------------------------------------------------------
      # darwinConfigurations — nix-darwin host for the MacBook.
      # Home Manager is embedded as a nix-darwin module so that the single
      # `darwin-rebuild switch` command activates both system and user config.
      # -----------------------------------------------------------------------
      darwinConfigurations.macbook = darwin.lib.darwinSystem {
        specialArgs = { inherit username; };
        system = systems.mac;
        modules = [
          ./hosts/macbook/default.nix
          sops-nix.darwinModules.sops
          home-manager.darwinModules.home-manager
          {
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
        specialArgs = { inherit username; };
        system = systems.linux;
        modules = [
          ./hosts/nixos/default.nix
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          {
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
      # packages — installable via `nix profile install .#bootstrap-deps`.
      # bootstrap-deps is a symlink-joined set of the tools that bootstrap.sh
      # needs before the full configuration has been applied (gnupg, jq, sops).
      # -----------------------------------------------------------------------
      packages = {
        "${systems.mac}".bootstrap-deps = pkgsMac.symlinkJoin {
          name = "bootstrap-deps";
          paths = [
            pkgsMac.gnupg
            pkgsMac.jq
            pkgsMac.sops
          ];
        };
        "${systems.linux}".bootstrap-deps = pkgsLinux.symlinkJoin {
          name = "bootstrap-deps";
          paths = [
            pkgsLinux.gnupg
            pkgsLinux.jq
            pkgsLinux.sops
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
            pkgsMac.jq
            pkgsMac.sops
          ];
        };
        "${systems.linux}".bootstrap = pkgsLinux.mkShell {
          packages = [
            pkgsLinux.gnupg
            pkgsLinux.jq
            pkgsLinux.sops
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
