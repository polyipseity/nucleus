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
      # Manage gpg-agent.conf declaratively so pinentry config and flags survive
      # redeployments; without this, losing the file silently breaks signing.
      settings = {
        pinentry-program = "${pkgs.pinentry_mac}/bin/pinentry-mac";
        # Allow programs to supply passphrases via --passphrase/--status-fd for
        # non-interactive signing contexts (scripts, CI).
        allow-loopback-pinentry = true;
      };
    };
  }
