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
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { darwin, home-manager, nixpkgs, sops-nix, ... }:
    let
      username = "polyipseity";
      systems = {
        linux = "x86_64-linux";
        mac = "aarch64-darwin";
      };
      mkPkgs = system: import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
      pkgsLinux = mkPkgs systems.linux;
      pkgsMac = mkPkgs systems.mac;
      mkApplyApp = pkgs: {
        type = "app";
        program = "${pkgs.writeShellApplication {
          name = "nucleus-apply";
          runtimeInputs = [ pkgs.git pkgs.gnupg pkgs.jq pkgs.sops ];
          text = builtins.readFile ./scripts/apply.sh;
        }}/bin/nucleus-apply";
      };
    in {
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

      # macOS (nix-darwin)
      darwinConfigurations.macbook = darwin.lib.darwinSystem {
        specialArgs = { inherit username; };
        system = systems.mac;
        modules = [
          ./hosts/macbook/default.nix
          sops-nix.darwinModules.sops
          home-manager.darwinModules.home-manager
          {
            home-manager.extraSpecialArgs = { inherit username; };
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.${username} = {
              imports = [
                sops-nix.homeManagerModules.sops
                ./modules/home.nix
              ];
            };
          }
        ];
      };

      # Linux (NixOS)
      nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit username; };
        system = systems.linux;
        modules = [
          ./hosts/nixos/default.nix
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          {
            home-manager.extraSpecialArgs = { inherit username; };
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.${username} = {
              imports = [
                sops-nix.homeManagerModules.sops
                ./modules/home.nix
              ];
            };
          }
        ];
      };

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

      # Generic CLI profile (works for Linux and WSL; can also drive cross-platform dotfiles)
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
