# vms/windows/packer.pkr.hcl — Packer template for building a Windows 11 QCOW2 image.
#
# Builds an unattended Windows 11 installation using QEMU.  The resulting
# QCOW2 disk image is pre-configured with VirtIO drivers and WinRM disabled,
# ready for use as the Windows VM guest declared in src/modules/VMs.json.
#
# Usage (from repo root):
#   cd vms/windows && packer init . && packer build \
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
#   2. Autounattend.xml partitions, installs, and enables WinRM.
#   3. Packer connects via WinRM and installs VirtIO drivers from the internet.
#   4. WinRM is disabled at the end; the image boots as a standard Windows 11 VM.
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

variable "winrm_timeout" {
  type        = string
  default     = "3h"
  description = "Timeout for WinRM communicator readiness (for slow emulation paths use a larger value such as 8h)."
}

packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "~> 1"
    }
  }
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
  machine_type   = "q35"

  memory     = var.memory
  cpus       = var.cpus
  net_device = "e1000"

  iso_url      = var.windows_iso
  iso_checksum = var.windows_iso_checksum

  # Autounattend.xml on floppy (A:\) — Windows Setup reads it automatically.
  floppy_files = [
    "${path.root}/Autounattend.xml",
  ]

  # WinRM communicator: Autounattend.xml enables WinRM during oobeSystem.
  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_password = "packer"
  winrm_port     = 5985
  winrm_timeout  = var.winrm_timeout

  # WHY: QEMU's automatic communicator NAT mapping can select a port mapping
  # that never reaches the guest on slow Windows boots.  Pin the host-forwarded
  # WinRM port explicitly so Packer and QEMU agree on 5985.
  skip_nat_mapping = true

  # WHY: The Windows bootmgr "Press any key to boot from CD or DVD" prompt
  # appears unpredictably under tcg (software emulation) — typically 10–120s
  # after VM start depending on host CPU speed.  Sending 3 Enter presses in a
  # 4-second window at t=50–54s misses the prompt whenever it appears outside
  # that narrow range (which happens on both fast and slow hosts).
  #
  # Solution: start sending Enter at t=10s (after BIOS POST) and repeat every
  # 10s for 200s total (20 presses), covering t=10s to t=210s from VM start.
  # The installer ignores extra Enter presses once Windows PE is loading.
  # This approach is used by community Windows QEMU Packer builds and is the
  # recommended technique for reliably catching the bootmgr prompt under tcg.
  boot_wait = "5s"
  boot_command = [
    "<return><wait10>", "<return><wait10>", "<return><wait10>", "<return><wait10>",
    "<return><wait10>", "<return><wait10>", "<return><wait10>", "<return><wait10>",
    "<return><wait10>", "<return><wait10>", "<return><wait10>", "<return><wait10>",
    "<return><wait10>", "<return><wait10>", "<return><wait10>", "<return><wait10>",
    "<return><wait10>", "<return><wait10>", "<return><wait10>", "<return><wait10>",
  ]

  # WHY: Packer's WinRM communicator starts probing as soon as boot_command
  # completes.  Even with 8h timeout, excessive early retries during Windows
  # PE / first-install / OOBE waste log space and obscure real errors.
  # 120s gives Windows time to complete the OOBE AutoLogon and reach a usable
  # shell before probes begin; the 8h winrm_timeout handles the rest.
  pause_before_connecting = "120s"

  qemuargs = [
    ["-netdev", "user,id=user.0,hostfwd=tcp::5985-:5985"],
  ]

  headless = true

  # NOTE: qemu plugin v1.1.x does not support `secondary_iso_images` on all
  # hosts. VirtIO drivers are installed by the PowerShell provisioner below
  # using a runtime download from the stable Fedora mirror.

  output_directory = var.output_directory
  vm_name          = "windows.qcow2"

  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer build complete\""
}

build {
  sources = ["source.qemu.windows11"]

  # Install VirtIO drivers so the finished image boots with the virtio disk
  # interface used in the vm-setup configurations (libvirt XML, UTM plist, and
  # QEMU start scripts).  Drivers are downloaded from the stable Fedora mirror.
  #
  # pnputil /add-driver with /install pre-stages the driver in the Windows
  # driver store; it takes effect when the device appears (i.e. when the image
  # is re-mounted with the virtio interface in the final VM).
  #
  # Source: https://fedorapeople.org/groups/virt/virtio-win/
  provisioner "powershell" {
    # Pause to let Windows fully settle after first logon.
    pause_before = "90s"
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "$virtioUrl = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso'",
      "$virtioIso = \"$env:TEMP\\virtio-win.iso\"",
      "Write-Host 'VM-build: downloading virtio-win.iso...'",
      "Invoke-WebRequest -Uri $virtioUrl -OutFile $virtioIso -UseBasicParsing",
      "$mountResult = Mount-DiskImage -ImagePath $virtioIso -PassThru",
      "$drive = ($mountResult | Get-Volume).DriveLetter + ':'",
      "Write-Host \"VM-build: installing VirtIO drivers from $drive\"",
      "pnputil /add-driver \"$drive\\viostor\\w11\\amd64\\viostor.inf\" /install",
      "pnputil /add-driver \"$drive\\NetKVM\\w11\\amd64\\netkvm.inf\" /install",
      "pnputil /add-driver \"$drive\\Balloon\\w11\\amd64\\balloon.inf\" /install",
      "Dismount-DiskImage -ImagePath $virtioIso",
      "Remove-Item $virtioIso -Force",
      "Write-Host 'VM-build: VirtIO drivers installed; image is VirtIO-disk ready'",
    ]
  }

  # Disable WinRM and clean up Packer build artefacts before finalising.
  provisioner "powershell" {
    inline = [
      "Write-Host 'VM-build: disabling WinRM'",
      "winrm set winrm/config/service @{AllowUnencrypted='false'}",
      "winrm set winrm/config/service/auth @{Basic='false'}",
      "netsh advfirewall firewall set rule group='windows remote management' new enable=no",
      "Write-Host 'VM-build: Windows 11 image finalised'",
    ]
  }
}
