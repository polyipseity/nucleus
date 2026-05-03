# nixos/hardware.nix — Hardware-specific kernel and driver settings.
{ ... }:
{
  # Kernel modules to include in the initial ramdisk so that block devices and
  # USB input are available before the main filesystem is mounted.
  # xhci_pci: USB 3.x host controller | nvme: NVMe SSD | usbhid: USB HID input
  # sd_mod: SCSI/SATA disk support (also required for some USB mass storage).
  boot.initrd.availableKernelModules = [ "xhci_pci" "nvme" "usbhid" "sd_mod" ];

  # Use the generic kernel modesetting driver rather than a vendor-specific
  # one; suitable for systems using Mesa or running under a hypervisor.
  services.xserver.videoDrivers = [ "modesetting" ];
}
