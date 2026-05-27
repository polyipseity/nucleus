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
#         https://github.com/pbatard/Fido
function Invoke-VMSetup {
    [CmdletBinding()]
    param(
        # Absolute path to the repository root.
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        # Path to the Windows 11 ISO. Optional when windowsIsoUrl is set in VMs.json;
        # the URL is used to auto-download the installer on first run.
        # Download from: https://www.microsoft.com/software-download/windows11
        [string]$WindowsIso = '',

        # Build and provision only the NixOS guest.
        [switch]$NixosOnly,

        # Build and provision only the Windows 11 guest.
        [switch]$WindowsOnly,

        # Windows installer ISO resolution strategy.
        # Auto: windowsIsoUrl cache/download first, then Fido fallback.
        # Url:  use only -WindowsIso or windowsIsoUrl (no downloader fallback).
        # Fido: use only local cache/Fido when -WindowsIso is omitted.
        [ValidateSet('Auto', 'Url', 'Fido')]
        [string]$WindowsIsoSource = 'Auto',

        # QEMU accelerator for image builds. Defaults to tcg (always works).
        # When tcg is used, Invoke-VMSetup auto-detects WHPX (Windows Hypervisor
        # Platform) and upgrades to whpx automatically if it is enabled.
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

    # Auto-detect WHPX when the user has not specified a non-default accelerator.
    # WHPX (Windows Hypervisor Platform) is significantly faster than tcg software
    # emulation and should be used when available.
    # Source: https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/user-guide/nested-virtualization
    if ($Accelerator -eq 'tcg') {
        try {
            $whpxFeature = Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -ErrorAction Stop
            if ($whpxFeature.State -eq 'Enabled') {
                $Accelerator = 'whpx'
                Write-Information 'vm-setup: WHPX detected; using whpx accelerator for faster VM builds'
            } else {
                Write-Warning 'vm-setup: WHPX is not enabled; using slow tcg accelerator. Enable for faster builds:'
                Write-Information 'vm-setup:   Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -NoRestart'
            }
        } catch {
            # Get-WindowsOptionalFeature requires elevation; skip detection and keep tcg.
            # Source: https://learn.microsoft.com/en-us/powershell/module/dism/get-windowsoptionalfeature
            Write-Information 'vm-setup: cannot detect WHPX (requires elevation); defaulting to tcg'
        }
    }

    # -------------------------------------------------------------------------
    # Phase 1 — Build images (if absent)
    # -------------------------------------------------------------------------

    foreach ($vm in $vmDef.VMs) {
        # Apply -NixosOnly / -WindowsOnly filter.
        if ($NixosOnly   -and $vm.type -ne 'NixOS')   { continue }
        if ($WindowsOnly -and $vm.type -ne 'Windows') { continue }

        switch ($vm.type) {
            'NixOS' {
                Invoke-BuildNixosImage -VmName $vm.name -Accelerator $Accelerator `
                    -VmsDir $vmsDir -ImagesDir $imagesDir -DryRun:$DryRun
            }
            'Windows' {
                # Convert SI bytes to nearest binary GiB for packer disk_size.
                $diskGib = [long](($vm.diskBytes + 536870912) / 1073741824)
                $isoUrl = if ($null -ne $vm.windowsIsoUrl) { [string]$vm.windowsIsoUrl } else { '' }
                Invoke-BuildWindowsImage -VmName $vm.name -DiskGib $diskGib `
                    -WindowsIso $WindowsIso -WindowsIsoUrl $isoUrl `
                    -WindowsIsoSource $WindowsIsoSource `
                    -RepoRoot $RepoRoot `
                    -WindowsEdition ($vm.windowsEdition ?? 'Pro') `
                    -Accelerator $Accelerator `
                    -VmsDir $vmsDir -ImagesDir $imagesDir -DryRun:$DryRun
            }
            'macOS' {
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
        if ($NixosOnly   -and $vm.type -ne 'NixOS')   { continue }
        if ($WindowsOnly -and $vm.type -ne 'Windows') { continue }

        # Convert SI bytes to nearest binary MiB for QEMU -m flag (which
        # interprets bare integers as MiB).
        $ramMib      = [long](($vm.ramBytes + 524288) / 1048576)
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

        if ($vm.type -eq 'Windows') {
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
# -object memory-backend-file,id=mem,size=$ramMib`M,mem-path=/dev/shm,share=on ``
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
    -m $ramMib ``
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
            'NixOS' {
@'
#!/usr/bin/env sh
# Apply the nucleus nixos host configuration inside this VM.
# ~/dev is shared via VirtioFS when shareDevDir=true.
sudo nixos-rebuild switch --flake "$HOME/dev/nucleus/src#NixOS"
'@
            }
            'Windows' {
@'
#!/usr/bin/env sh
# Apply the nucleus Windows host configuration inside this VM.
# Clone this repository to %USERPROFILE%\dev\nucleus inside the VM, then run:
#   .\src\hosts\Windows\apply.ps1
'@
            }
            'macOS' {
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

# Invoke-FidoWindowsIso — Download a Windows 11 ISO using vendor/Fido/Fido.ps1
# (the same engine that drives Rufus download automation).  Returns the full
# path to the downloaded ISO on success or an empty string on failure.
# Requires the vendor/Fido submodule to be checked out.
# Source: https://github.com/pbatard/Fido
function Invoke-FidoWindowsIso {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # Absolute path to the repository root (for locating vendor/Fido).
        [string]$RepoRoot,
        # Directory where the downloaded ISO will be placed.
        [string]$ImagesDir,
        # VM name — used to name the cached ISO file.
        [string]$VmName,
        # Windows edition to download (passed to Fido -Ed parameter).
        [string]$Edition = 'Pro',
        [switch]$DryRun
    )

    $fidoScript = Join-Path $RepoRoot 'vendor\Fido\Fido.ps1'
    if (-not (Test-Path $fidoScript)) {
        Write-Warning "vm-setup: Fido.ps1 not found at $fidoScript; run: git submodule update --init vendor/Fido"
        return ''
    }

    $cachedIso = Join-Path $ImagesDir "$VmName-installer.iso"

    if ($DryRun) {
        Write-Information "vm-setup: [dry-run] & '$fidoScript' -Win 11 -Ed $Edition -Lang English -Arch x64 -Download -NoPrompt"
        return $cachedIso
    }

    Write-Information "vm-setup: downloading Windows 11 ISO via Fido (edition=$Edition)..."
    # Run Fido in a temp dir; it downloads the ISO to the working directory.
    # Source: https://github.com/pbatard/Fido#usage
    $tmpDir = New-TemporaryFile | ForEach-Object { Remove-Item $_; New-Item -ItemType Directory -Path $_ }
    try {
        Push-Location $tmpDir
        try {
            & $fidoScript -Win 11 -Ed $Edition -Lang English -Arch x64 -Download -NoPrompt
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "vm-setup: Fido exited with code $LASTEXITCODE"
                return ''
            }
        } finally {
            Pop-Location
        }

        $downloadedIso = Get-ChildItem $tmpDir -Filter '*.iso' |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if (-not $downloadedIso) {
            Write-Warning 'vm-setup: Fido: no ISO found in temp dir after download'
            return ''
        }

        Move-Item $downloadedIso.FullName $cachedIso
        Write-Information "vm-setup: Windows ISO downloaded: $cachedIso"
        return $cachedIso
    } finally {
        # WHY: always clean up the temp dir; -ErrorAction SilentlyContinue is
        # acceptable here because temp-dir removal is a best-effort cleanup and
        # failure is benign (the OS will eventually clean it up).
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
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
        [int]$DiskGib,
        [string]$WindowsIso,
        # Optional URL to auto-download the Windows installer ISO when -WindowsIso
        # is not provided.  Set via the windowsIsoUrl field in VMs.json.
        [string]$WindowsIsoUrl = '',
        [ValidateSet('Auto', 'Url', 'Fido')]
        [string]$WindowsIsoSource = 'Auto',
        [string]$Accelerator,
        [string]$VmsDir,
        [string]$ImagesDir,
        [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))))),
        [string]$WindowsEdition = 'Pro',
        [switch]$DryRun
    )

    $outPath = Join-Path $ImagesDir "$VmName.qcow2"
    if (Test-Path $outPath) {
        Write-Information "vm-setup: Windows image already built (delete to rebuild): $outPath"
        return
    }

    # Resolve the installer ISO: use -WindowsIso if provided, otherwise try the
    # VMs.json windowsIsoUrl field as a download source.
    if (-not $WindowsIso -and $WindowsIsoSource -ne 'Fido' -and $WindowsIsoUrl) {
        $cachedIso = Join-Path $ImagesDir "$VmName-installer.iso"
        if (Test-Path $cachedIso) {
            Write-Information "vm-setup: using cached Windows installer: $cachedIso"
            $WindowsIso = $cachedIso
        } else {
            Write-Information "vm-setup: downloading Windows installer from windowsIsoUrl..."
            if (-not $DryRun) {
                # Use curl.exe (available on Windows 10 1803+) for large ISO downloads;
                # Invoke-WebRequest buffers the full file in memory before writing to disk.
                # Source: https://curl.se/docs/manpage.html
                if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
                    Write-Warning 'vm-setup: curl.exe not found; Windows 10 1803+ includes it in system32'
                    return
                }
                & curl.exe -fL -o $cachedIso $WindowsIsoUrl
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "vm-setup: download failed; removing partial file $cachedIso"
                    Remove-Item $cachedIso -Force -ErrorAction SilentlyContinue
                    return
                }
                $WindowsIso = $cachedIso
                Write-Information "vm-setup: Windows installer downloaded: $cachedIso"
            } else {
                Write-Information "vm-setup: [dry-run] curl.exe -fL -o $cachedIso $WindowsIsoUrl"
            }
        }
    }

    # If still no ISO resolved, attempt download via vendor/Fido/Fido.ps1.
    if (-not $WindowsIso -and $WindowsIsoSource -ne 'Url') {
        $cachedIso = Join-Path $ImagesDir "$VmName-installer.iso"
        if (Test-Path $cachedIso) {
            Write-Information "vm-setup: using cached Windows installer: $cachedIso"
            $WindowsIso = $cachedIso
        } else {
            $WindowsIso = Invoke-FidoWindowsIso `
                -RepoRoot $RepoRoot `
                -ImagesDir $ImagesDir `
                -VmName $VmName `
                -Edition $WindowsEdition `
                -DryRun:$DryRun
        }
    }
    # If ISO is still empty after all resolution attempts, fail with instructions.
    if (-not $WindowsIso) {
        if ($WindowsIsoSource -eq 'Url') {
            Write-Information 'vm-setup: windowsIsoSource=Url selected and no cached URL-based installer was resolved'
        }
        Write-Information 'vm-setup: alternatively add "windowsIsoUrl": "<url>" to the VMs.json windows entry'
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

    Write-Information "vm-setup: building Windows 11 image (disk=${DiskGib} GiB, accelerator=$Accelerator)..."
    Write-Information 'vm-setup: this takes ~30-90 minutes; VirtIO drivers are downloaded from the internet'

    # Pre-download VirtIO drivers ISO so it can be injected via secondary_iso_images,
    # enabling Autounattend.xml FirstLogonCommands early driver installation.
    # Falls back to runtime download in the Packer provisioner if this fails.
    # Source: https://fedorapeople.org/groups/virt/virtio-win/
    $VirtioIso = Join-Path $ImagesDir 'virtio-win.iso'
    if (-not (Test-Path $VirtioIso)) {
        if (-not $DryRun) {
            Write-Information 'vm-setup: downloading VirtIO drivers ISO...'
            $VirtioUrl = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso'
            try {
                Invoke-WebRequest -Uri $VirtioUrl -OutFile $VirtioIso -UseBasicParsing
                Write-Information "vm-setup: VirtIO ISO downloaded: $VirtioIso"
            } catch {
                Write-Warning "vm-setup: VirtIO ISO pre-download failed ($_); Packer provisioner will download at runtime"
                $VirtioIso = ''
            }
        } else {
            Write-Information "vm-setup: [dry-run] would download VirtIO ISO to $VirtioIso"
            $VirtioIso = ''
        }
    }

    if ($DryRun) {
        Write-Information "vm-setup: [dry-run] cd $packerDir; packer init .; packer build -var windows_iso=$WindowsIso -var accelerator=$Accelerator -var disk_size=${DiskGib}G -var output_directory=$tmpOutput ."
        return
    }

    Push-Location $packerDir
    try {
        & packer init .
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'vm-setup: packer init failed for Windows'
            return
        }
        $packerArgs = @(
            '-var', "windows_iso=$WindowsIso"
        )
        if ($VirtioIso) {
            $packerArgs += '-var', "virtio_win_iso=$VirtioIso"
        }
        $packerArgs += @(
            '-var', "accelerator=$Accelerator",
            '-var', "disk_size=${DiskGib}G",
            '-var', "output_directory=$tmpOutput",
            '.'
        )
        & packer build @packerArgs
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
