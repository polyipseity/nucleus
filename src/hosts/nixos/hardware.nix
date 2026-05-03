{ ... }:
{
  boot.initrd.availableKernelModules = [ "xhci_pci" "nvme" "usbhid" "sd_mod" ];

  services.xserver.videoDrivers = [ "modesetting" ];
}
