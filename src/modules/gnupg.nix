# Shared GnuPG runtime settings for non-Home-Manager hosts.
{
  lib,
  pkgs,
  options,
  ...
}:
lib.mkIf
  (
    pkgs.stdenv.isDarwin
    && options ? programs
    && options.programs ? gnupg
    && options.programs.gnupg ? agent
  )
  {
    # Keep the nix-darwin GnuPG agent enabled so the runtime daemon follows the
    # same derivation line as the CLI tools installed from pkgs.
    programs.gnupg.agent = {
      enable = true;
      enableSSHSupport = true;
    };

    # Write gpg-agent.conf via activation script because nix-darwin at the
    # pinned revision (a1fa429) does not expose programs.gnupg.agent.settings.
    # Without this file, pinentry-program defaults to the first on PATH and
    # allow-loopback-pinentry is unset, breaking non-interactive signing.
    system.activationScripts.postActivation.text = lib.mkAfter (
      builtins.replaceStrings [ "__PINENTRY_MAC_BIN__" ] [ "${pkgs.pinentry_mac}/bin/pinentry-mac" ] (
        builtins.readFile ../scripts/lib/configure-gpg-agent.sh
      )
    );
  }
