# src/vms/nixos/packer.pkr.hcl — Packer template for building a NixOS QCOW2 image.
#
# Used by src/hosts/Windows/modules/system/Invoke-VMSetup.ps1 on Windows hosts
# to build the NixOS guest image via QEMU. On macOS/NixOS hosts,
# scripts/vm-setup.sh uses nixos-generators directly (faster, no Packer
# needed).
#
# Usage (from repo root):
#   cd src/vms/nixos && packer init . && packer build \
#     [-var accelerator=whpx] \
#     -var guest_username=<username> \
#     -var guest_password=<password> \
#     .
#
# Accelerator options:
#   whpx  — Windows HyperVisor Platform (fast; requires enabling in Windows
#            Features: "Windows Hypervisor Platform")
#   tcg   — Software emulation (slow; works everywhere)
#
# Output: <output_directory>/nixos.qcow2
#
# Source: https://developer.hashicorp.com/packer/plugins/builders/qemu
#         https://nixos.org/manual/nixos/stable/index.html#sec-installation-manual
#
# ISO URL and checksum are pinned to a specific build.  Run bump-lockfile to
# update them; the lockfile (src/lockfiles/lockfile.json) is the source of truth.

variable "nixos_iso_url" {
  type        = string
  description = "URL to the NixOS minimal installation ISO (from lockfile vm-setup.nixos-iso section)."
}

variable "nixos_iso_checksum" {
  type        = string
  description = "Checksum for the NixOS ISO (sha256:...; from lockfile vm-setup.nixos-iso section)."
}

variable "accelerator" {
  type        = string
  default     = "tcg"
  description = "QEMU accelerator: whpx (Windows HyperVisor Platform) or tcg (software)."
}

variable "output_directory" {
  type        = string
  default     = "output"
  description = "Directory to write the finished QCOW2 image into."
}

variable "disk_size" {
  type        = string
  default     = "64000000000"
  description = "Boot disk size in bytes matching VMs.json diskSize for the NixOS guest (64GB)."
}

variable "memory" {
  type        = number
  default     = 4096
  description = "RAM in MiB during the build."
}

variable "cpus" {
  type        = number
  default     = 4
  description = "vCPUs during the build."
}

variable "guest_username" {
  type        = string
  description = "Primary login username for the built NixOS guest."
}

variable "guest_password" {
  type        = string
  description = "Password for the primary NixOS guest user."
}

variable "guest_hostname" {
  type        = string
  description = "Guest hostname from the VMs.json hostname field, rendered into configuration.nix as networking.hostName."
}

packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "1.1.4"
    }
  }
}

source "qemu" "nixos" {
  accelerator    = var.accelerator
  disk_interface = "virtio"
  disk_size      = var.disk_size
  format         = "qcow2"
  machine_type   = "q35"
  memory         = var.memory
  cpus           = var.cpus
  net_device     = "virtio-net"

  iso_url      = var.nixos_iso_url
  iso_checksum = var.nixos_iso_checksum

  # SSH communicator: root login is available by default on the NixOS minimal
  # ISO once sshd is started and a root password is set via boot_command.
  communicator = "ssh"
  ssh_username = "root"
  ssh_password = "packer"
  ssh_timeout  = "20m"

  # headless = true suppresses the QEMU window; use false for debugging.
  headless = true

  # boot_command: NixOS minimal boots to an autologin root console within ~40s.
  # Set root password and start sshd so the SSH communicator can connect.
  boot_wait = "40s"
  boot_command = [
    # Set root password so SSH can authenticate
    "passwd root<enter><wait2>",
    "packer<enter><wait>",
    "packer<enter><wait>",
    # Ensure sshd is running
    "systemctl start sshd<enter><wait5>",
  ]

  output_directory = var.output_directory
  vm_name          = "nixos.qcow2"

  shutdown_command = "shutdown -h now"
}

build {
  sources = ["source.qemu.nixos"]

  # Partition, format, and install NixOS onto /dev/vda.
  # The configuration mirrors src/vms/nixos/guest.nix used by nixos-generators.
  provisioner "shell" {
    timeout = "60m"
    inline = [
      # Partition: MBR with swap + Btrfs root (parity with qcow-btrfs guest format)
      "parted -s /dev/vda -- mklabel msdos",
      "parted -s /dev/vda -- mkpart primary btrfs 1MiB -2GiB",
      "parted -s /dev/vda -- mkpart primary linux-swap -2GiB 100%",
      "mkfs.btrfs -f /dev/vda1",
      "mkswap /dev/vda2",
      # Mount
      "mount /dev/vda1 /mnt",
      "swapon /dev/vda2",
      # Generate hardware configuration
      "nixos-generate-config --root /mnt",
      # Write the nucleus NixOS guest configuration
      <<-EOT
        cat > /mnt/etc/nixos/configuration.nix << 'NIXEOF'
        { modulesPath, ... }:
        {
          imports = [ ./hardware-configuration.nix "$${modulesPath}/profiles/qemu-guest.nix" ];
          boot.loader.grub.enable = true;
          boot.loader.grub.device = "/dev/vda";
      networking.hostName = "${var.guest_hostname}";
          users.users."${var.guest_username}" = {
            isNormalUser = true;
            extraGroups = [ "wheel" ];
            initialPassword = "${var.guest_password}";
          };
          system.stateVersion = "25.05";
        }
        NIXEOF
      EOT
      ,
      # Install
      "nixos-install --no-root-passwd",
    ]
  }
}
