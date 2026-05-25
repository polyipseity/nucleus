# Invoke-VMSetup.ps1 — Build VM images (if needed) and provision VMs on Windows.
#
# Combines the former Invoke-VMBuild and Invoke-VMSetup into one module.
# Phase 1 (build): builds pre-built QCOW2 images using Packer for each VM
# declared in src\modules\VMs.json, if absent at
# %USERPROFILE%\virtual machines\images\<name>.qcow2.  For NixOS guests on
# Windows, Packer downloads the NixOS ISO automatically (vms\nixos\packer.pkr.hcl).
# For Windows 11 guests, a local ISO is required (-WindowsIso).
#
# Phase 2 (provision): creates QEMU start scripts and places disk images for
# each VM.  Disk images are copied from the built images, eliminating the manual
# OS installation step previously required with empty disks.
#
# Called by scripts\vm-setup.ps1 (alias: nucleus-vm-setup).
# Not invoked automatically during nucleus apply — run manually when setting
# up a new machine or rebuilding VM images.
#
# Source: https://developer.hashicorp.com/packer/plugins/builders/qemu
#         https://www.qemu.org/docs/master/system/invocation.html
function Invoke-VMSetup {
    [CmdletBinding()]
    param(
        # Absolute path to the repository root.
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        # Path to the Windows 11 ISO. Required for Windows 11 guest builds.
        # Download from: https://www.microsoft.com/software-download/windows11
        [string]$WindowsIso = '',

        # Build and provision only the NixOS guest.
        [switch]$NixosOnly,

        # Build and provision only the Windows 11 guest.
        [switch]$WindowsOnly,

        # QEMU accelerator for image builds. Defaults to tcg (always works).
        # Use whpx for Windows HyperVisor Platform acceleration (requires enabling
        # "Windows Hypervisor Platform" in Windows Features).
        # Source: https://developer.hashicorp.com/packer/plugins/builders/qemu
        [string]$Accelerator = 'tcg',

        # Print planned actions without modifying any state.
        [switch]$DryRun
    )

    $ErrorActionPreference = 'Stop'

    $manifest = Join-Path $RepoRoot 'src\modules\VMs.json'
    if (-not (Test-Path $manifest)) {
        Write-Information "vm-setup: manifest not found at $manifest; skipping"
        return
    }

    $vmDef     = Get-Content $manifest -Raw | ConvertFrom-Json
    $vmsDir    = Join-Path $RepoRoot 'vms'
    $vmDir     = Join-Path $env:USERPROFILE 'virtual machines'
    $imagesDir = Join-Path $vmDir 'images'

    if (-not $DryRun) {
        New-Item -ItemType Directory -Path $vmDir     -Force | Out-Null
        New-Item -ItemType Directory -Path $imagesDir -Force | Out-Null
    } else {
        Write-Information "vm-setup: [dry-run] New-Item Directory $vmDir"
        Write-Information "vm-setup: [dry-run] New-Item Directory $imagesDir"
    }

    # -------------------------------------------------------------------------
    # Phase 1 — Build images (if absent)
    # -------------------------------------------------------------------------

    foreach ($vm in $vmDef.VMs) {
        # Apply -NixosOnly / -WindowsOnly filter.
        if ($NixosOnly   -and $vm.type -ne 'nixos')   { continue }
        if ($WindowsOnly -and $vm.type -ne 'windows') { continue }

        switch ($vm.type) {
            'nixos' {
                Invoke-BuildNixosImage -VmName $vm.name -Accelerator $Accelerator `
                    -VmsDir $vmsDir -ImagesDir $imagesDir -DryRun:$DryRun
            }
            'windows' {
                Invoke-BuildWindowsImage -VmName $vm.name -DiskGiB $vm.diskGiB `
                    -WindowsIso $WindowsIso -Accelerator $Accelerator `
                    -VmsDir $vmsDir -ImagesDir $imagesDir -DryRun:$DryRun
            }
            'macos' {
                Write-Information "vm-setup: macOS image must be obtained manually (licensing restricts automation)"
            }
            default {
                Write-Information "vm-setup: skipping build for '$($vm.name)' (unsupported type: $($vm.type))"
            }
        }
    }

    # -------------------------------------------------------------------------
    # Phase 2 — Provision VMs
    # -------------------------------------------------------------------------

    # Locate qemu-img from the Scoop-managed QEMU installation.
    $scoopQemuDir = Join-Path $env:USERPROFILE 'scoop\apps\qemu\current'
    $qemuImg = Join-Path $scoopQemuDir 'qemu-img.exe'
    if (-not (Test-Path $qemuImg)) {
        $qemuImgInPath = Get-Command qemu-img -ErrorAction SilentlyContinue
        if ($qemuImgInPath) {
            $qemuImg = $qemuImgInPath.Source
        } else {
            $qemuImg = $null
        }
    }

    foreach ($vm in $vmDef.VMs) {
        # Apply -NixosOnly / -WindowsOnly filter.
        if ($NixosOnly   -and $vm.type -ne 'nixos')   { continue }
        if ($WindowsOnly -and $vm.type -ne 'windows') { continue }

        $diskPath    = Join-Path $vmDir "$($vm.name).qcow2"
        $startScript = Join-Path $vmDir "Start-$($vm.display).ps1"
        $prebuilt    = Join-Path $imagesDir "$($vm.name).qcow2"

        Write-Information "vm-setup: configuring VM '$($vm.display)'..."

        # Place disk image from pre-built image (empty disk fallback removed).
        if (Test-Path $diskPath) {
            Write-Information "vm-setup: disk already exists: $diskPath"
        } elseif (Test-Path $prebuilt) {
            Write-Information "vm-setup: using pre-built image: $prebuilt"
            if (-not $DryRun) {
                Copy-Item $prebuilt $diskPath
            } else {
                Write-Information "vm-setup: [dry-run] Copy-Item '$prebuilt' '$diskPath'"
            }
        } else {
            Write-Warning "vm-setup: image not found for '$($vm.name)': $prebuilt; skipping"
            continue
        }

        # Determine the QEMU system binary and machine type based on host arch.
        $hostArch = $env:PROCESSOR_ARCHITECTURE
        if ($hostArch -eq 'ARM64') {
            $qemuSystem = Join-Path $scoopQemuDir 'qemu-system-aarch64.exe'
            $machine = 'virt'
            $cpu = 'host'
        } else {
            $qemuSystem = Join-Path $scoopQemuDir 'qemu-system-x86_64.exe'
            $machine = 'q35'
            $cpu = 'host'
        }

        if ($vm.type -eq 'windows') {
            $display = 'sdl'
            $vga = 'std'
        } else {
            $display = 'sdl'
            $vga = 'virtio'
        }

        # Determine VirtioFS shared directory argument.
        $virtiofsArgs = ''
        if ($vm.shareDevDir) {
            $devDir = Join-Path $env:USERPROFILE 'dev'
            # VirtioFS on Windows requires virtiofsd running separately.
            # Add a placeholder reminder; the start script shows how to launch
            # virtiofsd before starting the guest.
            $virtiofsArgs = @"

# To enable ~/dev directory sharing:
# 1. Start virtiofsd in a separate terminal:
#      virtiofsd --socket-path=\\.\pipe\$($vm.name)-virtiofs --shared-dir="$devDir"
# 2. Then run this script.
# -chardev socket,id=char0,path=\\.\pipe\$($vm.name)-virtiofs ``
# -device vhost-user-fs-pci,chardev=char0,tag=dev ``
# -object memory-backend-file,id=mem,size=$($vm.ramMiB)M,mem-path=/dev/shm,share=on ``
# -numa node,memdev=mem
"@
        }

        # Write a self-contained QEMU start script for this VM.
        $startContent = @"
# Start-$($vm.display).ps1 — Start the '$($vm.display)' QEMU virtual machine.
# Generated by Invoke-VMSetup; re-run ``nucleus-vm-setup`` to regenerate.
#
# Source: https://www.qemu.org/docs/master/system/invocation.html
$virtiofsArgs
& '$qemuSystem' ``
    -name '$($vm.display)' ``
    -machine $machine ``
    -cpu $cpu ``
    -smp $($vm.cpus) ``
    -m $($vm.ramMiB) ``
    -drive file='$diskPath',format=qcow2,if=virtio ``
    -netdev user,id=net0 ``
    -device virtio-net-pci,netdev=net0 ``
    -vga $vga ``
    -display $display ``
    -enable-kvm ``
    -rtc base=localtime ``
    -usb -device usb-tablet
"@

        if ($DryRun) {
            Write-Information "vm-setup: [dry-run] Write start script: $startScript"
        } else {
            Set-Content -Path $startScript -Value $startContent -Encoding UTF8
            Write-Information "vm-setup: start script written: $startScript"
        }

        # Write a configuration reference script for the guest OS.
        $configureScript = Join-Path $vmDir "$($vm.name)-configure.sh"
        $configureContent = switch ($vm.type) {
            'nixos' {
@'
#!/usr/bin/env sh
# Apply the nucleus nixos host configuration inside this VM.
# ~/dev is shared via VirtioFS when shareDevDir=true.
sudo nixos-rebuild switch --flake "$HOME/dev/nucleus/src#nixos"
'@
            }
            'windows' {
@'
#!/usr/bin/env sh
# Apply the nucleus Windows host configuration inside this VM.
# Clone this repository to %USERPROFILE%\dev\nucleus inside the VM, then run:
#   .\src\hosts\windows\apply.ps1
'@
            }
            'macos' {
@'
#!/usr/bin/env sh
# Apply the nucleus macbook host configuration inside this VM.
# Clone this repository to ~/dev/nucleus inside the VM, then run:
#   ~/dev/nucleus/scripts/bootstrap.sh apply
'@
            }
            default { $null }
        }
        if ($null -ne $configureContent) {
            if ($DryRun) {
                Write-Information "vm-setup: [dry-run] Write configure script: $configureScript"
            } else {
                Set-Content -Path $configureScript -Value $configureContent -Encoding UTF8
                Write-Information "vm-setup: configure script written: $configureScript"
            }
        }

        Write-Information "vm-setup: VM '$($vm.display)' setup complete"
    }

    Write-Information 'vm-setup: Windows VM setup complete'
    Write-Information "vm-setup: Disk images at: $vmDir"
    Write-Information 'vm-setup: Run the generated Start-*.ps1 scripts to launch VMs'
}

# Invoke-BuildNixosImage — Builds the NixOS guest image using Packer.
#
# On macOS/NixOS, scripts/vm-setup.sh uses nixos-generators directly (faster,
# no Packer needed).  On Windows, Packer with the QEMU builder downloads the
# NixOS minimal ISO and runs a shell provisioner to install NixOS
# (vms\nixos\packer.pkr.hcl).
function Invoke-BuildNixosImage {
    [CmdletBinding()]
    param(
        [string]$VmName,
        [string]$Accelerator,
        [string]$VmsDir,
        [string]$ImagesDir,
        [switch]$DryRun
    )

    $outPath = Join-Path $ImagesDir "$VmName.qcow2"
    if (Test-Path $outPath) {
        Write-Information "vm-setup: NixOS image already built (delete to rebuild): $outPath"
        return
    }

    if (-not (Get-Command packer -ErrorAction SilentlyContinue)) {
        Write-Warning 'vm-setup: packer not found; install via WinGet (HashiCorp.Packer)'
        return
    }

    $packerDir = Join-Path $VmsDir 'nixos'
    $tmpOutput = Join-Path $ImagesDir "${VmName}-build"

    Write-Information "vm-setup: building NixOS image (accelerator=$Accelerator)..."

    if ($DryRun) {
        Write-Information "vm-setup: [dry-run] cd $packerDir; packer init .; packer build -var accelerator=$Accelerator -var output_directory=$tmpOutput ."
        return
    }

    Push-Location $packerDir
    try {
        & packer init .
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'vm-setup: packer init failed for NixOS'
            return
        }
        & packer build `
            -var "accelerator=$Accelerator" `
            -var "output_directory=$tmpOutput" `
            .
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'vm-setup: packer build failed for NixOS'
            return
        }
    }
    finally {
        Pop-Location
    }

    $builtImage = Join-Path $tmpOutput 'nixos.qcow2'
    if (-not (Test-Path $builtImage)) {
        Write-Warning "vm-setup: Packer did not produce $builtImage"
        return
    }

    Move-Item $builtImage $outPath
    Remove-Item $tmpOutput -Recurse -Force
    Write-Information "vm-setup: NixOS image ready: $outPath"
}

# Invoke-BuildWindowsImage — Builds the Windows 11 guest image using Packer.
#
# Requires a Windows 11 ISO path (-WindowsIso).  Uses SATA disk during the
# build (no VirtIO drivers needed during install) then installs VirtIO drivers
# post-install so the resulting image boots with the VirtIO disk interface used
# during normal operation.
function Invoke-BuildWindowsImage {
    [CmdletBinding()]
    param(
        [string]$VmName,
        [int]$DiskGiB,
        [string]$WindowsIso,
        [string]$Accelerator,
        [string]$VmsDir,
        [string]$ImagesDir,
        [switch]$DryRun
    )

    $outPath = Join-Path $ImagesDir "$VmName.qcow2"
    if (Test-Path $outPath) {
        Write-Information "vm-setup: Windows image already built (delete to rebuild): $outPath"
        return
    }

    if (-not $WindowsIso) {
        Write-Warning 'vm-setup: -WindowsIso PATH is required for Windows 11 builds'
        Write-Information 'vm-setup: download from: https://www.microsoft.com/software-download/windows11'
        return
    }

    if (-not (Test-Path $WindowsIso)) {
        Write-Warning "vm-setup: Windows ISO not found: $WindowsIso"
        return
    }

    if (-not (Get-Command packer -ErrorAction SilentlyContinue)) {
        Write-Warning 'vm-setup: packer not found; install via WinGet (HashiCorp.Packer)'
        return
    }

    $packerDir = Join-Path $VmsDir 'windows'
    $tmpOutput = Join-Path $ImagesDir "${VmName}-build"

    Write-Information "vm-setup: building Windows 11 image (disk=${DiskGiB}G, accelerator=$Accelerator)..."
    Write-Information 'vm-setup: this takes ~30-90 minutes; VirtIO drivers are downloaded from the internet'

    if ($DryRun) {
        Write-Information "vm-setup: [dry-run] cd $packerDir; packer init .; packer build -var windows_iso=$WindowsIso -var accelerator=$Accelerator -var disk_size=${DiskGiB}G -var output_directory=$tmpOutput ."
        return
    }

    Push-Location $packerDir
    try {
        & packer init .
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'vm-setup: packer init failed for Windows'
            return
        }
        & packer build `
            -var "windows_iso=$WindowsIso" `
            -var "accelerator=$Accelerator" `
            -var "disk_size=${DiskGiB}G" `
            -var "output_directory=$tmpOutput" `
            .
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'vm-setup: packer build failed for Windows'
            return
        }
    }
    finally {
        Pop-Location
    }

    $builtImage = Join-Path $tmpOutput 'windows.qcow2'
    if (-not (Test-Path $builtImage)) {
        Write-Warning "vm-setup: Packer did not produce $builtImage"
        return
    }

    Move-Item $builtImage $outPath
    Remove-Item $tmpOutput -Recurse -Force
    Write-Information "vm-setup: Windows 11 image ready: $outPath"
}
