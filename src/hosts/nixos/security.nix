{ ... }:
{
  security.sudo.extraConfig = ''
    Defaults timestamp_timeout=5
  '';
}
