{ ... }:
{
  networking.applicationFirewall = {
    allowSigned = true;
    blockAllIncoming = false;
    enable = true;
    enableStealthMode = false;
  };

  networking.computerName = "macbook";
  networking.hostName = "macbook";
  networking.localHostName = "macbook";
}
