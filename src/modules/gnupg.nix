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
    system.activationScripts.postActivation.text = lib.mkAfter ''
      # ---- configureGpgAgent ----------------------------------------------------
      # WHY: /dev/console may not exist (headless/SSH session); empty result means no console user, handled downstream.
      _console_home="/Users/$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)"
      if [ -n "$_console_home" ] && [ "$_console_home" != "/Users/root" ]; then
        /bin/mkdir -p "$_console_home/.gnupg"
        /bin/chmod 700 "$_console_home/.gnupg"
        echo "pinentry-program ${pkgs.pinentry_mac}/bin/pinentry-mac" > "$_console_home/.gnupg/gpg-agent.conf"
        echo "allow-loopback-pinentry" >> "$_console_home/.gnupg/gpg-agent.conf"
      fi
    '';
  }
