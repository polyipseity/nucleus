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
  };

  outputs = { darwin, home-manager, nixpkgs, ... }:
    let
      username = "user"; # TODO: Change this to your local username.
      systems = {
        mac = "aarch64-darwin";
        linux = "x86_64-linux";
      };
      mkPkgs = system: import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
    in {
      # macOS (nix-darwin)
      darwinConfigurations.macbook = darwin.lib.darwinSystem {
        system = systems.mac;
        modules = [
          ./hosts/macbook/default.nix
          home-manager.darwinModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = { inherit username; };
            home-manager.users.${username} = import ./modules/home.nix;
          }
        ];
      };

      # Linux (NixOS)
      nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
        system = systems.linux;
        modules = [
          ./hosts/nixos/configuration.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = { inherit username; };
            home-manager.users.${username} = import ./modules/home.nix;
          }
        ];
      };

      # Generic CLI profile (works for Linux and WSL; can also drive cross-platform dotfiles)
      homeConfigurations.${username} = home-manager.lib.homeManagerConfiguration {
        pkgs = mkPkgs systems.linux;
        extraSpecialArgs = { inherit username; };
        modules = [ ./modules/home.nix ];
      };
    };
}
