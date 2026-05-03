{
  description = "MacBook IaC";

  inputs = {
    # Home Manager shares the same nixpkgs revision as the rest of the stack.
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # Nixvim keeps Neovim and plugin configuration declarative.
    nixvim.url = "github:nix-community/nixvim";
    nixvim.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { home-manager, nix-darwin, nixvim, ... }:
  let
    hostName = "MacBook";

    # setup.sh runs nix-darwin through sudo, so SUDO_USER is normally set.
    # USER fallback keeps manual invocations usable.
    currentUserName =
      let
        sudoUser = builtins.getEnv "SUDO_USER";
        shellUser = builtins.getEnv "USER";
      in
      if sudoUser != "" then sudoUser
      else if shellUser != "" then shellUser
      else throw ''
        Could not determine the active user.
        Run through setup.sh or export USER before invoking nix.
      '';

    # Keep this as a list so scaling to multiple managed users is trivial.
    userList = [ currentUserName ];
  in {
    darwinConfigurations.${hostName} = nix-darwin.lib.darwinSystem {
      # Expose runtime values to configuration.nix.
      specialArgs = {
        inherit currentUserName hostName userList;
      };

      modules = [
        ./configuration.nix
        nixvim.nixDarwinModules.nixvim
        home-manager.darwinModules.home-manager
      ];
    };
  };
}
