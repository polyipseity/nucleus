# src/hosts/windows/modules/system/Invoke-VMBuild.ps1
#
# Builds pre-built QCOW2 VM disk images consumed by Invoke-VMSetup.ps1.
#
# Produces images at %USERPROFILE%\virtual machines\images\<name>.qcow2
# for each VM declared in src\modules\VMs.json.  Invoke-VMSetup.ps1 detects
# these and uses them in place of empty disks, eliminating the manual OS
# installation step.
#
# Called by scripts\VM-build.ps1 (alias: nucleus-VM-build).
# Not invoked automatically during nucleus apply — run manually when setting
# up a new machine or rebuilding VM images.
#
# VM type build strategies:
#   nixos   — Packer QEMU builder + NixOS minimal ISO (vms\nixos\packer.pkr.hcl)
#   windows — Packer QEMU builder + Windows 11 ISO + Autounattend.xml
#             (vms\windows\packer.pkr.hcl)
#
# Source: https://developer.hashicorp.com/packer/plugins/builders/qemu

function Invoke-VMBuild {
    [CmdletBinding()]
    param(
        # Path to the Windows 11 ISO. Required for Windows 11 guest builds.
        # Download from: https://www.microsoft.com/software-download/windows11
        [string]$WindowsIso = '',

        # Build only the NixOS guest image.
        [switch]$NixosOnly,

        # Build only the Windows 11 guest image.
        [switch]$WindowsOnly,

        # QEMU accelerator.  Defaults to tcg (software emulation, always works).
        # Use whpx for Windows HyperVisor Platform acceleration (requires enabling
        # "Windows Hypervisor Platform" in Windows Features).
        [string]$Accelerator = 'tcg',

        # Print planned actions without executing.
        [switch]$DryRun
    )

    $ErrorActionPreference = 'Stop'

    # Locate the repository root via this module's known relative position.
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\..') |
        Select-Object -ExpandProperty Path

    $manifest = Join-Path $repoRoot 'src\modules\VMs.json'
    if (-not (Test-Path $manifest)) {
        Write-Warning "VM-build: manifest not found: $manifest"
        return
    }

    $vmDef     = Get-Content $manifest -Raw | ConvertFrom-Json
    $vmsDir    = Join-Path $repoRoot 'vms'
    $imagesDir = Join-Path $env:USERPROFILE 'virtual machines\images'

    if (-not $DryRun) {
        New-Item -ItemType Directory -Path $imagesDir -Force | Out-Null
    }

    foreach ($vm in $vmDef.vms) {
        switch ($vm.type) {
            'nixos' {
                if (-not $WindowsOnly) {
                    Invoke-BuildNixosImage -VmName $vm.name -Accelerator $Accelerator `
                        -VmsDir $vmsDir -ImagesDir $imagesDir `
                        -DryRun:$DryRun
                }
            }
            'windows' {
                if (-not $NixosOnly) {
                    Invoke-BuildWindowsImage -VmName $vm.name -DiskGiB $vm.diskGiB `
                        -WindowsIso $WindowsIso -Accelerator $Accelerator `
                        -VmsDir $vmsDir -ImagesDir $imagesDir `
                        -DryRun:$DryRun
                }
            }
            default {
                Write-Information "VM-build: skipping '$($vm.name)' (unsupported type: $($vm.type))"
            }
        }
    }

    if (-not $DryRun) {
        Write-Information "VM-build: images at $imagesDir"
        Write-Information 'VM-build: run nucleus-VM-setup to provision VM disks using the built images'
    }
}

# Invoke-BuildNixosImage — Builds the NixOS guest image using Packer.
#
# On macOS/NixOS, scripts/VM-build.sh uses nixos-generators directly (faster).
# On Windows, Packer with the QEMU builder downloads the NixOS minimal ISO and
# runs a shell provisioner to install NixOS (vms\nixos\packer.pkr.hcl).
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
        Write-Information "VM-build: NixOS image already exists (delete to rebuild): $outPath"
        return
    }

    if (-not (Get-Command packer -ErrorAction SilentlyContinue)) {
        Write-Warning 'VM-build: packer not found; install via WinGet (HashiCorp.Packer)'
        return
    }

    $packerDir = Join-Path $VmsDir 'nixos'
    $tmpOutput = Join-Path $ImagesDir "${VmName}-build"

    Write-Information "VM-build: building NixOS image (accelerator=$Accelerator)..."

    if ($DryRun) {
        Write-Information "VM-build: [dry-run] cd $packerDir; packer init .; packer build -var accelerator=$Accelerator -var output_directory=$tmpOutput ."
        return
    }

    Push-Location $packerDir
    try {
        & packer init .
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'VM-build: packer init failed for NixOS'
            return
        }
        & packer build `
            -var "accelerator=$Accelerator" `
            -var "output_directory=$tmpOutput" `
            .
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'VM-build: packer build failed for NixOS'
            return
        }
    }
    finally {
        Pop-Location
    }

    $builtImage = Join-Path $tmpOutput 'nixos.qcow2'
    if (-not (Test-Path $builtImage)) {
        Write-Warning "VM-build: Packer did not produce $builtImage"
        return
    }

    Move-Item $builtImage $outPath
    Remove-Item $tmpOutput -Recurse -Force
    Write-Information "VM-build: NixOS image ready: $outPath"
}

# Invoke-BuildWindowsImage — Builds the Windows 11 guest image using Packer.
#
# Requires a Windows 11 ISO path.  Uses SATA disk during build (no VirtIO
# drivers needed during install) then installs VirtIO drivers post-install so
# the resulting image boots with the VirtIO disk interface used in VM-setup.
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
        Write-Information "VM-build: Windows image already exists (delete to rebuild): $outPath"
        return
    }

    if (-not $WindowsIso) {
        Write-Warning 'VM-build: -WindowsIso PATH is required for Windows 11 builds'
        Write-Information 'VM-build: download from: https://www.microsoft.com/software-download/windows11'
        return
    }

    if (-not (Test-Path $WindowsIso)) {
        Write-Warning "VM-build: Windows ISO not found: $WindowsIso"
        return
    }

    if (-not (Get-Command packer -ErrorAction SilentlyContinue)) {
        Write-Warning 'VM-build: packer not found; install via WinGet (HashiCorp.Packer)'
        return
    }

    $packerDir = Join-Path $VmsDir 'windows'
    $tmpOutput = Join-Path $ImagesDir "${VmName}-build"

    Write-Information "VM-build: building Windows 11 image (disk=${DiskGiB}G, accelerator=$Accelerator)..."
    Write-Information 'VM-build: this takes ~30-90 minutes; VirtIO drivers are downloaded from the internet'

    if ($DryRun) {
        Write-Information "VM-build: [dry-run] cd $packerDir; packer init .; packer build -var windows_iso=$WindowsIso -var accelerator=$Accelerator -var disk_size=${DiskGiB}G -var output_directory=$tmpOutput ."
        return
    }

    Push-Location $packerDir
    try {
        & packer init .
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'VM-build: packer init failed for Windows'
            return
        }
        & packer build `
            -var "windows_iso=$WindowsIso" `
            -var "accelerator=$Accelerator" `
            -var "disk_size=${DiskGiB}G" `
            -var "output_directory=$tmpOutput" `
            .
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'VM-build: packer build failed for Windows'
            return
        }
    }
    finally {
        Pop-Location
    }

    $builtImage = Join-Path $tmpOutput 'windows.qcow2'
    if (-not (Test-Path $builtImage)) {
        Write-Warning "VM-build: Packer did not produce $builtImage"
        return
    }

    Move-Item $builtImage $outPath
    Remove-Item $tmpOutput -Recurse -Force
    Write-Information "VM-build: Windows 11 image ready: $outPath"
}
