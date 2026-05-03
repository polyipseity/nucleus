{ ... }:
{
  security.pam.services.sudo_local.touchIdAuth = true;

  system.activationScripts.configureSudoTimeout.text = ''
    echo "Defaults timestamp_timeout=5" > /etc/sudoers.d/10-timeout
    chmod 440 /etc/sudoers.d/10-timeout
  '';
}
