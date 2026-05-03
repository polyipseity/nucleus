{ lib, pkgs, options, ... }:
let
  sharedPackages = [
    pkgs.bat
    pkgs.bottom
    pkgs.direnv
    pkgs.eza
    pkgs.fd
    pkgs.fzf
    pkgs.git
    pkgs.gnupg
    pkgs.jq
    pkgs.ripgrep
    pkgs.rustup
    pkgs.sops
    pkgs.uv
    pkgs.zoxide
  ] ++ lib.optionals pkgs.stdenv.isDarwin [
    pkgs.desktoppr
    pkgs.duti
    pkgs.pinentry_mac
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
