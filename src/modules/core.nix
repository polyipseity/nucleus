# modules/core.nix — Cross-platform package set shared by every managed host.
#
# The same list of packages is injected whether the caller is nix-darwin
# (system-level packages go into environment.systemPackages), NixOS (same
# option), or a standalone Home Manager profile (home.packages).  A runtime
# options-probe via lib.mkMerge + lib.mkIf lets this single module work in all
# three contexts without the caller having to know which option is appropriate.
{ lib, pkgs, options, ... }:
let
  # Packages installed on every host regardless of OS:
  #   bat        — syntax-highlighted cat replacement
  #   bottom     — cross-platform system monitor (btm)
  #   direnv     — per-directory env loader (shell integration in shell.nix)
  #   eza        — modern ls with colour and icons
  #   fd         — fast find replacement
  #   fzf        — fuzzy finder used by shell widgets and neovim
  #   git        — version control
  #   gnupg      — GPG for secret management and signing
  #   jq         — JSON processor used by activation scripts
  #   ripgrep    — fast grep replacement
  #   rustup     — Rust toolchain manager
  #   sops       — secret encryption/decryption tool
  #   uv         — fast Python package/project manager
  #   zoxide     — smart cd (shell integration in shell.nix)
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
    # Darwin-only extras:
    #   desktoppr  — set desktop wallpaper from the command line
    #   duti       — set default application for a UTI (used in macos.nix)
    #   pinentry_mac — macOS-native GPG PIN entry dialog
    pkgs.desktoppr
    pkgs.duti
    pkgs.pinentry_mac
  ];
in
# Probe the module option tree at evaluation time to decide which option to
# populate.  Both branches may match simultaneously (e.g. nix-darwin with
# Home Manager), so mkMerge is used to merge both results safely.
lib.mkMerge [
  (lib.mkIf (options ? environment && options.environment ? systemPackages) {
    environment.systemPackages = sharedPackages;
  })

  (lib.mkIf (options ? home && options.home ? packages) {
    home.packages = sharedPackages;
  })
]
