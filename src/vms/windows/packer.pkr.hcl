# src/vms/windows/packer.pkr.hcl — Packer template for building a Windows 11 QCOW2 image.
#
# Builds an unattended Windows 11 installation using QEMU.  The resulting
# QCOW2 disk image is pre-configured with VirtIO drivers, OpenSSH, and qemu-ga,
# ready for use as the Windows VM guest declared in src/modules/VMs.json.
#
# Usage (from repo root):
#   cd src/vms/windows && packer init . && packer build \
#     -var windows_iso=/path/to/Windows11.iso \
#     [-var accelerator=hvf]                  \
#     .
#
# Accelerator options:
#   hvf   — Hypervisor.framework (macOS; enabled by default on Apple Silicon)
#   kvm   — Kernel-based VM (Linux)
#   whpx  — Windows HyperVisor Platform (Windows; requires enabling the
#            "Windows Hypervisor Platform" optional feature)
#   tcg   — Software emulation (slow; works everywhere without privileges)
#
# Windows 11 ISO:
#   Download from: https://www.microsoft.com/software-download/windows11
#   The answer file (Autounattend.xml) selects "Windows 11 Pro" automatically.
#
# Output: <output_directory>/windows.qcow2
#
# Build strategy:
#   1. Boot with SATA disk so Windows Setup does not need VirtIO drivers.
#   2. Autounattend.xml partitions, installs, and enables SSH.
#   3. Packer connects via SSH and installs VirtIO drivers + qemu-ga from the internet.
#   4. The image boots as a standard Windows 11 VM with OpenSSH and qemu-ga ready.
#
# Source: https://developer.hashicorp.com/packer/plugins/builders/qemu

variable "windows_iso" {
  type        = string
  description = "Path to the Windows 11 ISO. Download from https://www.microsoft.com/software-download/windows11"
}

variable "windows_iso_checksum" {
  type        = string
  default     = "none"
  description = "Checksum for the Windows 11 ISO (sha256:...).  Set to 'none' to skip verification."
}

variable "accelerator" {
  type        = string
  default     = "kvm"
  description = "QEMU accelerator: hvf (macOS), kvm (Linux), whpx (Windows), or tcg."
}

variable "output_directory" {
  type        = string
  default     = "output"
  description = "Directory to write the finished QCOW2 image into."
}

variable "disk_size" {
  type        = string
  default     = "128G"
  description = "Boot disk size matching VMs.json diskGiB for the Windows guest."
}

variable "memory" {
  type        = number
  default     = 8192
  description = "RAM in MiB during the build (match VMs.json ramMiB)."
}

variable "cpus" {
  type        = number
  default     = 4
  description = "vCPUs during the build (match VMs.json cpus)."
}

variable "boot_strategy" {
  type        = string
  default     = "spacebar"
  description = "BIOS installer boot strategy: none, spacebar, alpha, or legacy."
}

variable "firmware_mode" {
  type        = string
  default     = "bios"
  description = "Firmware mode: bios or efi."
}

variable "efi_firmware_code" {
  type        = string
  default     = ""
  description = "Path to EFI firmware CODE file (used when firmware_mode=efi)."
}

variable "efi_firmware_vars" {
  type        = string
  default     = ""
  description = "Path to EFI firmware VARS file (used when firmware_mode=efi)."
}

variable "headless" {
  type        = bool
  default     = true
  description = "Whether to run QEMU headless during build (set false for interactive debugging)."
}

variable "display_backend" {
  type        = string
  default     = ""
  description = "QEMU display backend to use for headful builds (for example: cocoa, gtk, sdl)."
}

variable "guest_username" {
  type        = string
  default     = "packer"
  description = "Primary login username for the guest and SSH communicator."
}

variable "guest_password" {
  type        = string
  default     = "packer"
  description = "Primary login password for the guest and SSH communicator."
}

variable "ssh_timeout" {
  type        = string
  default     = "3h"
  description = "Maximum time to wait for SSH communicator.  Wrapper scripts set this per build attempt firmware/boot strategy."
}

variable "autounattend_path" {
  type        = string
  default     = "./Autounattend.xml"
  description = "Path to the rendered Autounattend.xml consumed by Windows Setup.  Wrapper scripts pass the full resolved path."
}

packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "~> 1"
    }
  }
}

locals {
  # WHY: Windows BIOS installs can require one "any key" press to boot from ISO.
  # Different host accelerators and QEMU builds behave differently, so callers
  # can choose the strategy per attempt instead of hard-coding one fragile path.
  #
  # Strategy summary:
  #   none     — do not send any keypresses (works when firmware auto-boots ISO)
  #   spacebar — safe explicit "any key" cadence (~4m)
  #   alpha    — alphanumeric fallback (~4m)
  #   legacy   — extended dense+slow coverage for worst-case tcg timing
  #
  # Packer HCL range() is capped at 1024 values per expression.
  bootPromptSpacebarPhase   = [for _ in range(0, 240) : "<spacebar><wait>"]
  bootPromptAlphaPhase      = [for _ in range(0, 240) : "a<wait>"]
  bootPromptAnyKeyDensePhase = [for _ in range(0, 1024) : "a<wait>"]
  bootPromptAnyKeySlowPhase  = [for _ in range(0, 1024) : "a<wait20>"]

  # WHY: Some EFI boots land in the UEFI shell instead of auto-launching the
  # installer.  Do not rely on startup.nsh on floppy (it is not always mapped
  # as a filesystem); send direct ISO loader paths instead.
  bootPromptEfiDirect = [
    "<wait5><enter><wait1>fs0:\\EFI\\Microsoft\\Boot\\cdboot_noprompt.efi<enter><wait1>fs0:\\EFI\\BOOT\\BOOTX64.EFI<enter><wait1>fs1:\\EFI\\Microsoft\\Boot\\cdboot_noprompt.efi<enter><wait1>fs1:\\EFI\\BOOT\\BOOTX64.EFI<enter>",
  ]

  bootPromptByStrategy = local.efiEnabled ? local.bootPromptEfiDirect : (
    var.boot_strategy == "none" ? [] :
    var.boot_strategy == "spacebar" ? local.bootPromptSpacebarPhase :
    var.boot_strategy == "alpha" ? local.bootPromptAlphaPhase :
    concat(local.bootPromptAnyKeyDensePhase, local.bootPromptAnyKeySlowPhase)
  )

  efiEnabled = var.firmware_mode == "efi"

  # WHY: EFI-first attempts avoid BIOS "Press any key" fragility for Windows
  # ISOs. Wrapper scripts can pass host-specific firmware paths explicitly.
  efiCodeResolved = local.efiEnabled ? (
    var.efi_firmware_code != "" ? var.efi_firmware_code :
    "/Applications/UTM.app/Contents/Resources/qemu/edk2-x86_64-code.fd"
  ) : ""

  efiVarsResolved = local.efiEnabled ? (
    var.efi_firmware_vars != "" ? var.efi_firmware_vars :
    "/Applications/UTM.app/Contents/Resources/qemu/edk2-i386-vars.fd"
  ) : ""

  # WHY: The qemu builder defaults to gtk when headless=false, but some QEMU
  # packages (including this Darwin profile) do not ship gtk support.
  # Wrapper scripts pass a supported backend during interactive debug runs.
  displayBackendResolved = var.headless ? "none" : (
    var.display_backend != "" ? var.display_backend : "gtk"
  )
}

source "qemu" "windows11" {
  accelerator = var.accelerator

  # Use IDE during the build so Windows Setup sees the disk without
  # requiring VirtIO storage drivers to be present in the installer.
  # (SATA is not supported by qemu-system-x86_64 on some host builds,
  # including the Darwin arm64 package used by this repo.)
  # VirtIO drivers are injected by the PowerShell provisioner below,
  # so the finished image is compatible with VirtIO disk interface.
  disk_interface = "ide"
  disk_size      = var.disk_size
  disk_discard   = "unmap"
  format         = "qcow2"

  # WHY: qemu-img convert compaction can produce corrupted images on macOS in
  # some environments. Keep output as a direct qcow2 artifact copy path.
  # Source: https://raw.githubusercontent.com/hashicorp/packer-plugin-qemu/main/.web-docs/components/builder/qemu/README.md
  skip_compaction  = true
  disk_compression = false

  machine_type   = "q35"

  efi_boot          = local.efiEnabled
  efi_firmware_code = local.efiCodeResolved
  efi_firmware_vars = local.efiVarsResolved

  memory     = var.memory
  cpus       = var.cpus
  net_device = "e1000"

  iso_url      = var.windows_iso
  iso_checksum = var.windows_iso_checksum

  # Autounattend.xml on floppy (A:\) — Windows Setup reads it automatically.
  floppy_files = [
    var.autounattend_path,
  ]

  # WHY: Keep fallback commands available on floppy for manual shell recovery,
  # but EFI auto-keying uses direct ISO paths from bootPromptEfiDirect.
  floppy_content = {
    "startup.nsh" = <<-EOF
      map -r
      fs0:\EFI\Microsoft\Boot\cdboot_noprompt.efi
      fs0:\EFI\BOOT\BOOTX64.EFI
      fs1:\EFI\Microsoft\Boot\cdboot_noprompt.efi
      fs1:\EFI\BOOT\BOOTX64.EFI
    EOF
  }

  # SSH communicator: Autounattend.xml installs OpenSSH during specialize pass.
  communicator = "ssh"
  ssh_username = var.guest_username
  ssh_password = var.guest_password
  ssh_timeout  = var.ssh_timeout

  # WHY: Forward SSH (22) through QEMU's user-mode networking so Packer can
  # connect without needing a routable IP on the guest.
  skip_nat_mapping = true

  # WHY: Force CD-ROM first so fresh builds always reach Windows Setup even when
  # BIOS ignores/defers `once=` semantics and would otherwise boot the empty
  # hard disk. On post-install reboots, Windows setup still continues from disk
  # unless a key is pressed at the CD prompt.
  boot_wait    = "5s"
  boot_command = local.bootPromptByStrategy

  # WHY: Packer's SSH communicator starts probing as soon as boot_command
  # completes.  Even with 3h ssh_timeout, excessive early retries during Windows
  # PE / first-install / OOBE waste log space and obscure real errors.
  # 120s gives Windows time to complete the OOBE AutoLogon and reach a usable
  # shell before probes begin; the 3h ssh_timeout handles the rest.
  pause_before_connecting = "120s"

  qemuargs = [
    ["-boot", "order=d"],
    ["-netdev", "user,id=user.0,hostfwd=tcp::2222-:22"],
  ]

  headless = var.headless
  display  = local.displayBackendResolved

  # NOTE: qemu plugin v1.1.x does not support `secondary_iso_images` on all
  # hosts. VirtIO drivers are installed by the PowerShell provisioner below
  # using a runtime download from the stable Fedora mirror.

  output_directory = var.output_directory
  vm_name          = "windows.qcow2"

  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer build complete\""
}

build {
  sources = ["source.qemu.windows11"]

  # Install VirtIO drivers and QEMU guest agent (qemu-ga) from the stable
  # Fedora virtio-win guest-tools bundle.  This single installer packages both
  # the VirtIO storage/network/balloon drivers and the QEMU guest agent,
  # replacing the prior two-step ISO download + separate qemu-ga setup.
  #
  # pnputil /add-driver with /install pre-stages the driver in the Windows
  # driver store; it takes effect when the device appears (i.e. when the image
  # is re-mounted with the virtio interface in the final VM).
  #
  # Source: https://fedorapeople.org/groups/virt/virtio-win/
  provisioner "powershell" {
    pause_before = "90s"
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "$toolsUrl = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win-guest-tools.exe'",
      "$toolsExe = \"$env:TEMP\\virtio-win-guest-tools.exe\"",
      "Write-Host 'VM-build: downloading virtio-win-guest-tools.exe...'",
      "Invoke-WebRequest -Uri $toolsUrl -OutFile $toolsExe -UseBasicParsing",
      "Write-Host 'VM-build: installing VirtIO drivers + qemu-ga...'",
      "Start-Process -Wait -FilePath $toolsExe -ArgumentList '/quiet /install /norestart'",
      "Remove-Item $toolsExe -Force",
      "Write-Host 'VM-build: VirtIO drivers and qemu-ga installed'",
    ]
  }

}
