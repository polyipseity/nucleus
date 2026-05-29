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
  #   spacebar — safe explicit "any key" cadence (~17m)
  #   alpha    — alphanumeric fallback (~17m)
  #   legacy   — extended dense+slow coverage for worst-case tcg timing
  #
  # Packer HCL range() is capped at 1024 values per expression.
  bootPromptSpacebarPhase   = [for _ in range(0, 1024) : "<spacebar><wait>"]
  bootPromptAlphaPhase      = [for _ in range(0, 1024) : "a<wait>"]
  bootPromptAnyKeyDensePhase = [for _ in range(0, 1024) : "a<wait>"]
  bootPromptAnyKeySlowPhase  = [for _ in range(0, 1024) : "a<wait20>"]

  # WHY: Some EFI boots land in the UEFI shell instead of auto-launching the
  # installer. Put the launcher in startup.nsh so the shell can auto-run it
  # without relying on fragile VNC timing or manual confirmation keys.
  bootPromptEfiDirect = [
    "<wait5>fs1:\\startup.nsh<enter>",
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
    "${path.root}/Autounattend.xml",
  ]

  # WHY: The Windows installer ISO frequently lands in the UEFI shell on this
  # QEMU build. startup.nsh launches the installer script from the mapped floppy
  # without depending on shell keystroke timing.
  floppy_content = {
    "startup.nsh" = <<-EOF
      map -r
      fs0:
      \\EFI\\Microsoft\\Boot\\cdboot_noprompt.efi
    EOF
  }

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

  # WHY: QEMU should boot the installer ISO once and then fall back to the disk
  # on later reboots. Avoid synthetic boot keystrokes so SeaBIOS/UEFI do not get
  # stuck in their shell or boot menu prompts.
  boot_wait    = "5s"
  boot_command = []

  # WHY: Packer's WinRM communicator starts probing as soon as boot_command
  # completes.  Even with 8h timeout, excessive early retries during Windows
  # PE / first-install / OOBE waste log space and obscure real errors.
  # 120s gives Windows time to complete the OOBE AutoLogon and reach a usable
  # shell before probes begin; the 8h winrm_timeout handles the rest.
  pause_before_connecting = "120s"

  qemuargs = [
    ["-boot", "order=c,once=d"],
    ["-netdev", "user,id=user.0,hostfwd=tcp::5985-:5985"],
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
