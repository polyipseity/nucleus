# hosts/nixos/hardware/cpu.nix — CPU-adjacent early-boot module requirements.
#
# Keep initrd module ordering intact because early-boot probing depends on load
# sequence; this list is intentionally not alphabetized.
{ ... }:
{
  # Kernel modules to include in the initial ramdisk so block devices and USB
  # input are available before the root filesystem mounts.
  # xhci_pci: USB 3.x host controller | nvme: NVMe SSD | usbhid: USB HID input
  # sd_mod: SCSI/SATA disk support (also required for some USB mass storage).
  boot.initrd.availableKernelModules = [ "xhci_pci" "nvme" "usbhid" "sd_mod" ];
}
