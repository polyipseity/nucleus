{ lib, pkgs, options, ... }:
let
  sharedPackages = with pkgs; [
    bottom
    eza
    fd
    git
    gnupg
    jq
    ripgrep
    rustup
    sops
    zoxide
  ];
in
lib.mkMerge [
  (lib.mkIf (options ? environment && options.environment ? systemPackages) {
    environment.systemPackages = sharedPackages;
  })

  (lib.mkIf (options ? home && options.home ? packages) {
    home.packages = sharedPackages;
  })
]
