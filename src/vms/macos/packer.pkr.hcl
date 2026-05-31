# src/vms/macos/packer.pkr.hcl — Packer template for building a macOS guest using
# the Packer Tart plugin.  Only runs on Apple Silicon macOS hosts; Tart uses
# Apple's Virtualization.framework which is not available on other platforms.
#
# Pulls a base macOS image from the Cirrus CI OCI registry and provisions it
# for use as the nucleus macOS guest declared in src/modules/VMs.json.
#
# Usage (from repo root):
#   cd src/vms/macos && packer init . && packer build \
#     [-var macos_version=tahoe]                 \
#     [-var vm_name=MacBook]                     \
#     .
#
# Prerequisites:
#   - tart CLI installed (brew install cirruslabs/cli/tart)
#   - packer installed (pkgs.packer in baseSharedPackages)
#   - Apple Silicon Mac (Tart requires Virtualization.framework)
#
# The resulting VM is stored in ~/virtual machines/.tart/vms/<vm_name>/
# (via the ~/.tart symlink created by nucleus-vm-setup).
# Start with: tart run <vm_name> [--no-graphics]
#
# Source: https://github.com/cirruslabs/packer-plugin-tart
#         https://github.com/cirruslabs/tart
#         https://github.com/cirruslabs/macos-image-templates

variable "macos_version" {
  type        = string
  default     = "tahoe"
  description = "macOS version to provision (tahoe, sequoia, sonoma, ventura, etc.)."
}

variable "vm_name" {
  type        = string
  default     = "MacBook"
  description = "Name of the tart VM to create (stored in ~/virtual machines/.tart/vms/<vm_name> via ~/.tart symlink)."
}

variable "cpus" {
  type        = number
  default     = 4
  description = "vCPUs for the VM (match VMs.json cpus)."
}

variable "memory_gib" {
  type        = number
  default     = 8
  description = "RAM in GiB (match VMs.json ramMiB / 1024)."
}

variable "disk_size_gib" {
  type        = number
  default     = 128
  description = "Disk size in GiB (match VMs.json diskGiB)."
}

variable "guest_username" {
  type        = string
  default     = "admin"
  description = "Primary guest login username to provision."
}

variable "guest_password" {
  type        = string
  default     = "admin"
  description = "Primary guest login password to provision."
}

packer {
  required_plugins {
    tart = {
      source  = "github.com/cirruslabs/tart"
      version = "~> 1"
    }
  }
}

# Pull the official Cirrus CI base macOS image from GHCR.
# Base images ship with Xcode, Homebrew, and an admin user (admin/admin).
# Source: https://github.com/cirruslabs/macos-image-templates
source "tart-cli" "macos" {
  vm_base_name = "ghcr.io/cirruslabs/macos-${var.macos_version}-base:latest"
  vm_name      = var.vm_name

  cpu_count    = var.cpus
  memory_gb    = var.memory_gib
  disk_size_gb = var.disk_size_gib

  # Default credentials for all Cirrus CI base macOS images.
  ssh_username = "admin"
  ssh_password = "admin"
  ssh_timeout  = "120s"
}

build {
  sources = ["source.tart-cli.macos"]

  # Set the hostname to match the nucleus host display name convention
  # (host name equals display name: MacBook for the macOS guest).
  provisioner "shell" {
    inline = [
      "sudo scutil --set HostName MacBook",
      "sudo scutil --set ComputerName MacBook",
      "sudo scutil --set LocalHostName MacBook",
      "if id -u '${var.guest_username}' >/dev/null 2>&1; then sudo dscl . -passwd '/Users/${var.guest_username}' '${var.guest_password}'; else sudo sysadminctl -addUser '${var.guest_username}' -fullName '${var.guest_username}' -password '${var.guest_password}' -admin; fi",
      "echo 'macOS VM provisioned via Packer Tart'",
    ]
  }
}
