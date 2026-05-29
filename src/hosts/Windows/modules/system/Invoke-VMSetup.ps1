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

        # Retry attempts for Windows ISO network downloads.
        [int]$WindowsIsoRetries = 0,

        # QEMU accelerator for image builds. Defaults to tcg (always works).
        # When tcg is used, Invoke-VMSetup auto-detects WHPX (Windows Hypervisor
        # Platform) and upgrades to whpx automatically if it is enabled.
        # Source: https://developer.hashicorp.com/packer/plugins/builders/qemu
        [string]$Accelerator = 'tcg',

        # Run Windows image builds headful (headless=false) for interactive
        # debugging of installer/WinRM readiness issues.
        [switch]$DebugHeadful,

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

    $vmReadmePath = Join-Path $vmDir 'README.md'
    $vmReadmeContent = @'
# virtual machines

This directory stores VM artifacts managed by `nucleus-vm-setup`.

## Layout

- `images/` — build outputs, temporary build directories, and installer cache.
- `images/<name>.qcow2` — pre-built guest images produced in build phase.
- `images/<name>-build/` — temporary Packer output directory used during builds.
- `images/<name>-installer.iso` — cached Windows installer ISO used by rebuilds.
- `<name>.utm/` — UTM bundle directory on macOS hosts.
- `<name>.qcow2` — libvirt/QEMU runtime disk on Linux/Windows hosts.

## Start commands

- macOS guest (Tart): run `start-<name>.sh` or `start-<name>.ps1` from `~/virtual machines`
- NixOS/Windows guests on macOS (UTM): run `start-<name>.sh` or `start-<name>.ps1` from `~/virtual machines`
- NixOS/Windows guests on NixOS (libvirt): run `start-<name>.sh` or `start-<name>.ps1` from `~/virtual machines`
- NixOS/Windows guests on Windows (QEMU): run `start-<name>.ps1` (or `start-<name>.sh` in Git Bash/MSYS)

## UTM bundle portability

`*.utm` is a folder bundle (not a single opaque file). It contains VM metadata
plus disk data (typically `Data/disk-main.qcow2`).

To move a UTM VM to another macOS host:

1. Copy the entire `<name>.utm` directory.
2. Place it under `~/virtual machines/` on the target host.
3. Import it in UTM (or re-run `nucleus-vm-setup` so import automation can detect it).

Copying only `config.plist` or only `disk-main.qcow2` is not sufficient for a
portable UTM VM transfer.

## Guest configuration

Guest OS configuration is **not automatic** after first boot.
Run the generated helper script to print the exact guest-side converge command:

- `%USERPROFILE%\virtual machines\configure-<name>.ps1`
- `%USERPROFILE%\virtual machines\configure-<name>.sh`

Then run the command inside each guest:

- NixOS guest: `sudo nixos-rebuild switch --flake "$HOME/dev/nucleus/src#NixOS"`
- Windows guest: `.\src\hosts\Windows\apply.ps1` (from `%USERPROFILE%\dev\nucleus`)
- macOS guest: `~/dev/nucleus/scripts/bootstrap.sh apply`

## Safe cleanup

Temporary files/directories that are safe to remove when builds fail, are
interrupted, or when reclaiming space:

- `%USERPROFILE%\virtual machines\images\<name>-build\`
- `%USERPROFILE%\virtual machines\images\<name>-installer.iso`

Persistent VM artifacts (remove only when intentionally deleting a VM):

- `%USERPROFILE%\virtual machines\images\<name>.qcow2`
- `%USERPROFILE%\virtual machines\<name>.utm\`
- `%USERPROFILE%\virtual machines\<name>.qcow2`

If the installer cache is removed, `nucleus-vm-setup` re-downloads it on the
next run.

## Notes

- Keep this directory managed by `nucleus-vm-setup`; avoid hand-editing generated artifacts.
- Re-run `nucleus-vm-setup` after changing `src/modules/VMs.json`.
- macOS guest images are built and run with Tart today; automated Tart→UTM runtime handoff is not yet supported.
'@
    if ($DryRun) {
        Write-Information "vm-setup: [dry-run] Write VM directory guide: $vmReadmePath"
    } else {
        Set-Content -Path $vmReadmePath -Value $vmReadmeContent -Encoding UTF8
        Write-Information "vm-setup: VM directory guide written: $vmReadmePath"
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
                    -WindowsIsoRetries $WindowsIsoRetries `
                    -RepoRoot $RepoRoot `
                    -WindowsEdition ($vm.windowsEdition ?? 'Pro') `
                    -Accelerator $Accelerator `
                    -DebugHeadful:$DebugHeadful `
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
        $startScriptPs1 = Join-Path $vmDir "start-$($vm.name).ps1"
        $startScriptSh = Join-Path $vmDir "start-$($vm.name).sh"
        $configureScriptPs1 = Join-Path $vmDir "configure-$($vm.name).ps1"
        $configureScriptSh = Join-Path $vmDir "configure-$($vm.name).sh"
        $prebuilt    = Join-Path $imagesDir "$($vm.name).qcow2"

        Write-Information "vm-setup: configuring VM '$($vm.display)'..."

        $prebuiltValid = (Test-Path $prebuilt) -and (Test-Qcow2Image -ImagePath $prebuilt -ImageLabel "pre-built image '$($vm.name)'")

        # Place disk image from pre-built image (empty disk fallback removed).
        if (Test-Path $diskPath) {
            if (Test-Qcow2Image -ImagePath $diskPath -ImageLabel "runtime disk '$($vm.name)'") {
                Write-Information "vm-setup: disk already exists: $diskPath"
            } elseif ($prebuiltValid) {
                Write-Warning "vm-setup: existing runtime disk is invalid; replacing with pre-built image: $diskPath"
                if (-not $DryRun) {
                    Remove-Item $diskPath -Force
                    Copy-Item $prebuilt $diskPath
                } else {
                    Write-Information "vm-setup: [dry-run] Remove-Item '$diskPath' -Force"
                    Write-Information "vm-setup: [dry-run] Copy-Item '$prebuilt' '$diskPath'"
                }
            } else {
                Write-Warning "vm-setup: runtime disk is invalid and no valid pre-built image exists for '$($vm.name)'; skipping"
                continue
            }
        } elseif ($prebuiltValid) {
            Write-Information "vm-setup: using pre-built image: $prebuilt"
            if (-not $DryRun) {
                Copy-Item $prebuilt $diskPath
            } else {
                Write-Information "vm-setup: [dry-run] Copy-Item '$prebuilt' '$diskPath'"
            }
        } else {
            Write-Warning "vm-setup: image not found or invalid for '$($vm.name)': $prebuilt; skipping"
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
        $startContentPs1 = @"
    # start-$($vm.name).ps1 — Start the '$($vm.display)' QEMU virtual machine.
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
    -rtc base=localtime ``
    -usb -device usb-tablet
"@

        $startContentSh = @"
#!/usr/bin/env sh
# start-$($vm.name).sh — Start the '$($vm.display)' QEMU virtual machine.
# Generated by Invoke-VMSetup; re-run nucleus-vm-setup to regenerate.

set -eu

'$qemuSystem' \
    -name '$($vm.display)' \
    -machine $machine \
    -cpu $cpu \
    -smp $($vm.cpus) \
    -m $ramMib \
    -drive file='$diskPath',format=qcow2,if=virtio \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    -vga $vga \
    -display $display \
    -rtc base=localtime \
    -usb -device usb-tablet
"@

        if ($DryRun) {
            Write-Information "vm-setup: [dry-run] Write start scripts: $startScriptPs1, $startScriptSh"
        } else {
            Set-Content -Path $startScriptPs1 -Value $startContentPs1 -Encoding UTF8
            Set-Content -Path $startScriptSh -Value $startContentSh -Encoding UTF8
            Write-Information "vm-setup: start scripts written: $startScriptPs1, $startScriptSh"
        }

        # Write a helper script that prints the guest-side converge command.
        # WHY: guest configuration is intentionally manual after first boot;
        # this keeps the next step discoverable from the VM artifact directory.
        switch ($vm.type) {
            'NixOS' { $configureCommand = 'sudo nixos-rebuild switch --flake "$HOME/dev/nucleus/src#NixOS"' }
            'Windows' { $configureCommand = '.\src\hosts\Windows\apply.ps1' }
            'macOS' { $configureCommand = '~/dev/nucleus/scripts/bootstrap.sh apply' }
            default { $configureCommand = 'No guest converge command is defined for this VM type.' }
        }

        $configureContentPs1 = @"
# configure-$($vm.name).ps1 — Show guest configuration command for '$($vm.display)'.
# Generated by Invoke-VMSetup; re-run ``nucleus-vm-setup`` to regenerate.

Write-Host 'Guest configuration is not automatic. Run inside the guest:'
Write-Host ''
Write-Host '$configureCommand'
"@

        $configureContentSh = @"
#!/usr/bin/env sh
# configure-$($vm.name).sh — Show guest configuration command for '$($vm.display)'.
# Generated by Invoke-VMSetup; re-run nucleus-vm-setup to regenerate.

set -eu
printf 'Guest configuration is not automatic. Run inside the guest:\n\n'
printf '%s\n' '$configureCommand'
"@

        if ($DryRun) {
            Write-Information "vm-setup: [dry-run] Write configure scripts: $configureScriptPs1, $configureScriptSh"
        } else {
            Set-Content -Path $configureScriptPs1 -Value $configureContentPs1 -Encoding UTF8
            Set-Content -Path $configureScriptSh -Value $configureContentSh -Encoding UTF8
            Write-Information "vm-setup: configure helpers written: $configureScriptPs1, $configureScriptSh"
        }

        # Remove legacy helper scripts from %USERPROFILE%\virtual machines now
        # that helper scripts are regenerated with start-/configure- naming.
        $legacyHelpers = @(
            (Join-Path $vmDir "Start-$($vm.display).ps1"),
            (Join-Path $vmDir "Start-$($vm.display).sh"),
            (Join-Path $vmDir "$($vm.name)-configure.ps1"),
            (Join-Path $vmDir "$($vm.name)-configure.sh")
        )
        if (-not $DryRun) {
            foreach ($legacyHelper in $legacyHelpers) {
                if (Test-Path $legacyHelper) {
                    Remove-Item $legacyHelper -Force
                    Write-Information "vm-setup: removed legacy helper script: $legacyHelper"
                }
            }
        }

        Write-Information "vm-setup: VM '$($vm.display)' setup complete"
    }

    $legacyConfigureDir = Join-Path $env:LOCALAPPDATA 'nucleus\vms\configure'
    if (-not $DryRun -and (Test-Path $legacyConfigureDir)) {
        Remove-Item $legacyConfigureDir -Recurse -Force
        Write-Information "vm-setup: removed legacy helper directory: $legacyConfigureDir"
    }

    Write-Information 'vm-setup: Windows VM setup complete'
    Write-Information "vm-setup: Disk images at: $vmDir"
    Write-Information "vm-setup: VM directory guide at: $vmReadmePath"
    Write-Information 'vm-setup: Run the generated start-<name>.ps1 (or start-<name>.sh) scripts to launch VMs'
}

# Test-Qcow2Image — Validates a QCOW2 image file before reuse.
#
# Ensures the image exists, has a non-zero size, and (when qemu-img is
# available) reports format=qcow2 with a sensible virtual size.
function Test-Qcow2Image {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$ImagePath,

        [string]$ImageLabel = 'image'
    )

    if (-not (Test-Path $ImagePath)) {
        Write-Warning "vm-setup: $ImageLabel not found: $ImagePath"
        return $false
    }

    $item = Get-Item $ImagePath -ErrorAction SilentlyContinue
    if (-not $item -or $item.Length -le 0) {
        Write-Warning "vm-setup: $ImageLabel is empty or unreadable: $ImagePath"
        return $false
    }

    $qemuImg = Get-Command qemu-img -ErrorAction SilentlyContinue
    if (-not $qemuImg) {
        return $true
    }

    $infoJson = & $qemuImg.Source info --output=json $ImagePath 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $infoJson) {
        Write-Warning "vm-setup: qemu-img could not read ${ImageLabel}: $ImagePath"
        return $false
    }

    try {
        $info = $infoJson | ConvertFrom-Json
    } catch {
        Write-Warning "vm-setup: qemu-img returned invalid JSON for ${ImageLabel}: $ImagePath"
        return $false
    }

    if ($info.format -ne 'qcow2') {
        Write-Warning "vm-setup: $ImageLabel has unexpected format '$($info.format)' (expected qcow2): $ImagePath"
        return $false
    }

    if ([long]$info.'virtual-size' -lt 10737418240) {
        Write-Warning "vm-setup: $ImageLabel virtual size is too small ($($info.'virtual-size') bytes): $ImagePath"
        return $false
    }

    return $true
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
        if (Test-Qcow2Image -ImagePath $outPath -ImageLabel 'existing NixOS image') {
            Write-Information "vm-setup: NixOS image already built (delete to rebuild): $outPath"
            return
        }
        Write-Warning "vm-setup: existing NixOS image is invalid; rebuilding from scratch: $outPath"
        Remove-Item $outPath -Force
    }

    if (-not (Get-Command packer -ErrorAction SilentlyContinue)) {
        Write-Warning 'vm-setup: packer not found; install via WinGet (HashiCorp.Packer)'
        return
    }

    $packerDir = Join-Path $VmsDir 'nixos'
    $tmpOutput = Join-Path $ImagesDir "${VmName}-build"

    Write-Information "vm-setup: building NixOS image (accelerator=$Accelerator)..."

    if ($DryRun) {
        Write-Information "vm-setup: [dry-run] Remove stale temporary output directory if present: $tmpOutput"
        Write-Information "vm-setup: [dry-run] cd $packerDir; packer init .; packer build -var accelerator=$Accelerator -var output_directory=$tmpOutput ."
        return
    }

    # WHY: Packer qemu builder requires output_directory to not already exist.
    if (Test-Path $tmpOutput) {
        Remove-Item $tmpOutput -Recurse -Force
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

    if (-not (Test-Qcow2Image -ImagePath $outPath -ImageLabel 'newly built NixOS image')) {
        Write-Warning "vm-setup: NixOS image validation failed after build; removing $outPath"
        Remove-Item $outPath -Force
        return
    }

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
        # Retry attempts for transient network errors.
        [int]$Retries = 0,
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

    if ($Retries -lt 0) {
        Write-Warning "vm-setup: invalid retry count ($Retries); expected a non-negative integer"
        return ''
    }

    Write-Information "vm-setup: downloading Windows 11 ISO via Fido (edition=$Edition)..."
    # Run Fido in a temp dir; it downloads the ISO to the working directory.
    # Source: https://github.com/pbatard/Fido#usage
    $tmpDir = New-TemporaryFile | ForEach-Object { Remove-Item $_; New-Item -ItemType Directory -Path $_ }
    try {
        $maxAttempts = $Retries + 1
        $attempt = 1
        while ($attempt -le $maxAttempts) {
            Push-Location $tmpDir
            try {
                $fidoOutput = & $fidoScript -Win 11 -Ed $Edition -Lang English -Arch x64 -Download -NoPrompt 2>&1
                if ($fidoOutput) {
                    $fidoOutput | ForEach-Object { Write-Information "$_" }
                }
                if ($LASTEXITCODE -eq 0) {
                    break
                }

                if (($fidoOutput -join "`n") -match '715-123130') {
                    Write-Warning 'vm-setup: Microsoft blocked automated ISO download (code 715-123130); retry later or provide -WindowsIso path'
                }

                if ($attempt -ge $maxAttempts) {
                    Write-Warning "vm-setup: Fido exited with code $LASTEXITCODE"
                    return ''
                }

                $sleepSeconds = [Math]::Min([Math]::Pow(2, $attempt - 1), 30)
                Write-Warning "vm-setup: Fido download attempt $attempt/$maxAttempts failed; retrying in $sleepSeconds seconds"
                Start-Sleep -Seconds $sleepSeconds
                $attempt++
            } finally {
                Pop-Location
            }
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
        [int]$WindowsIsoRetries = 0,
        [string]$Accelerator,
        [string]$VmsDir,
        [string]$ImagesDir,
        [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))))),
        [string]$WindowsEdition = 'Pro',
        [switch]$DebugHeadful,
        [switch]$DryRun
    )

    $outPath = Join-Path $ImagesDir "$VmName.qcow2"
    if (Test-Path $outPath) {
        if (Test-Qcow2Image -ImagePath $outPath -ImageLabel 'existing Windows image') {
            Write-Information "vm-setup: Windows image already built (delete to rebuild): $outPath"
            return
        }
        Write-Warning "vm-setup: existing Windows image is invalid; rebuilding from scratch: $outPath"
        Remove-Item $outPath -Force
    }

    if ($WindowsIsoRetries -lt 0) {
        Write-Warning "vm-setup: invalid WindowsIsoRetries value ($WindowsIsoRetries); expected a non-negative integer"
        return
    }

    Write-Information "vm-setup: Windows ISO fallback order: cached installer -> windowsIsoUrl -> downloader ($WindowsIsoSource mode)"

    $cachedIso = Join-Path $ImagesDir "$VmName-installer.iso"
    if (-not $WindowsIso -and (Test-Path $cachedIso)) {
        Write-Information "vm-setup: using cached Windows installer: $cachedIso"
        $WindowsIso = $cachedIso
    }

    # Resolve the installer ISO: use -WindowsIso if provided, otherwise try the
    # VMs.json windowsIsoUrl field as a download source.
    if (-not $WindowsIso -and $WindowsIsoSource -ne 'Fido' -and $WindowsIsoUrl) {
        Write-Information "vm-setup: downloading Windows installer from windowsIsoUrl..."
        if (-not $DryRun) {
            # Use curl.exe (available on Windows 10 1803+) for large ISO downloads;
            # Invoke-WebRequest buffers the full file in memory before writing to disk.
            # Source: https://curl.se/docs/manpage.html
            if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
                Write-Warning 'vm-setup: curl.exe not found; Windows 10 1803+ includes it in system32'
                return
            }

            $maxAttempts = $WindowsIsoRetries + 1
            $attempt = 1
            $downloadOk = $false
            while ($attempt -le $maxAttempts) {
                & curl.exe -fL -o $cachedIso $WindowsIsoUrl
                if ($LASTEXITCODE -eq 0) {
                    $downloadOk = $true
                    break
                }

                if ($attempt -ge $maxAttempts) {
                    break
                }

                $sleepSeconds = [Math]::Min([Math]::Pow(2, $attempt - 1), 30)
                Write-Warning "vm-setup: windowsIsoUrl download attempt $attempt/$maxAttempts failed; retrying in $sleepSeconds seconds"
                Start-Sleep -Seconds $sleepSeconds
                $attempt++
            }

            if (-not $downloadOk) {
                Write-Warning "vm-setup: windowsIsoUrl download failed; removing partial file $cachedIso"
                if (Test-Path $cachedIso) {
                    Remove-Item $cachedIso -Force
                }
                return
            }

            $WindowsIso = $cachedIso
            Write-Information "vm-setup: Windows installer downloaded: $cachedIso"
        } else {
            Write-Information "vm-setup: [dry-run] curl.exe -fL -o $cachedIso $WindowsIsoUrl"
        }
    }

    # If still no ISO resolved, attempt download via vendor/Fido/Fido.ps1.
    if (-not $WindowsIso -and $WindowsIsoSource -ne 'Url') {
        $WindowsIso = Invoke-FidoWindowsIso `
            -RepoRoot $RepoRoot `
            -ImagesDir $ImagesDir `
            -VmName $VmName `
            -Edition $WindowsEdition `
            -Retries $WindowsIsoRetries `
            -DryRun:$DryRun
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
    # WHY: Under tcg software emulation, Windows setup + OOBE can take
    # substantially longer than hardware-accelerated paths. Keep timeout parity
    # with scripts/vm-setup.sh so long-running builds do not fail prematurely.
    $winrmTimeout = if ($Accelerator -eq 'tcg') { '72h' } else { '3h' }

    # WHY: This repository currently standardizes Windows guest runtime on BIOS
    # (for example src/hosts/MacBook/vms.nix keeps UEFIBoot=false and
    # Autounattend.xml uses BIOS partitioning). Keep build attempts BIOS-only by
    # default to avoid EFI shell loops.
    $efiCodeCandidates = @(
        (Join-Path $env:ProgramFiles 'qemu\share\qemu\edk2-x86_64-code.fd'),
        (Join-Path $env:ProgramFiles 'qemu\share\qemu\OVMF_CODE.fd')
    )
    $efiVarsCandidates = @(
        (Join-Path $env:ProgramFiles 'qemu\share\qemu\edk2-i386-vars.fd'),
        (Join-Path $env:ProgramFiles 'qemu\share\qemu\OVMF_VARS.fd')
    )
    $efiCode = $efiCodeCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    $efiVars = $efiVarsCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

    $buildAttempts = if ($Accelerator -eq 'tcg') {
        @(
            @{ Firmware = 'bios'; Boot = 'none'; Timeout = '8h' },
            @{ Firmware = 'bios'; Boot = 'spacebar'; Timeout = '8h' },
            @{ Firmware = 'bios'; Boot = 'alpha'; Timeout = '8h' },
            @{ Firmware = 'bios'; Boot = 'legacy'; Timeout = '72h' }
        )
    } else {
        @(
            @{ Firmware = 'bios'; Boot = 'none'; Timeout = '30m' },
            @{ Firmware = 'bios'; Boot = 'spacebar'; Timeout = '2h' },
            @{ Firmware = 'bios'; Boot = 'alpha'; Timeout = '2h' },
            @{ Firmware = 'bios'; Boot = 'legacy'; Timeout = $winrmTimeout }
        )
    }

    if ($efiCode -and $efiVars) {
        Write-Information "vm-setup: EFI firmware detected ($efiCode, $efiVars) but BIOS-only build policy is active"
    } else {
        Write-Information 'vm-setup: EFI firmware not detected; using BIOS-only build attempts'
    }

    # WHY: Packer HCL bool vars are easiest to pass as explicit true/false
    # strings from wrapper scripts for cross-shell consistency.
    $packerHeadless = if ($DebugHeadful) { 'false' } else { 'true' }
    $packerDisplayBackend = ''
    if ($DebugHeadful) {
        # WHY: Packer defaults to gtk for headful builds, but not every QEMU
        # package includes gtk support. Select from backends QEMU advertises.
        try {
            $qemuCommand = Get-Command qemu-system-x86_64 -ErrorAction Stop
        } catch {
            Write-Warning 'vm-setup: qemu-system-x86_64 not found; cannot run headful debug mode'
            return
        }

        $displayHelp = & $qemuCommand.Source -display help
        foreach ($candidate in @('sdl', 'gtk', 'spice-app', 'curses')) {
            if (($displayHelp -join "`n") -match "(^|\s)${candidate}(\s|$)") {
                $packerDisplayBackend = $candidate
                break
            }
        }
        if (-not $packerDisplayBackend) {
            Write-Warning "vm-setup: no supported headful QEMU display backend detected. Available backends:`n$($displayHelp -join "`n")"
            return
        }
    }

    Write-Information "vm-setup: building Windows 11 image (disk=${DiskGib} GiB, accelerator=$Accelerator)..."
    Write-Information 'vm-setup: this takes ~30-90 minutes; VirtIO drivers are downloaded from the internet'
    if ($DebugHeadful) {
        Write-Information 'vm-setup: debug mode enabled; running Windows Packer build headful (headless=false)'
        Write-Information "vm-setup: using QEMU display backend for debug run: $packerDisplayBackend"
    }

    if ($DryRun) {
        Write-Information "vm-setup: [dry-run] Remove stale temporary output directory if present: $tmpOutput"
        foreach ($attempt in $buildAttempts) {
            if ($attempt.Firmware -eq 'efi') {
                if ($DebugHeadful) {
                    Write-Information "vm-setup: [dry-run] cd $packerDir; packer build -var windows_iso=$WindowsIso -var accelerator=$Accelerator -var firmware_mode=$($attempt.Firmware) -var boot_strategy=$($attempt.Boot) -var winrm_timeout=$($attempt.Timeout) -var headless=$packerHeadless -var display_backend=$packerDisplayBackend -var efi_firmware_code=$efiCode -var efi_firmware_vars=$efiVars -var disk_size=${DiskGib}G -var output_directory=$tmpOutput ."
                } else {
                    Write-Information "vm-setup: [dry-run] cd $packerDir; packer build -var windows_iso=$WindowsIso -var accelerator=$Accelerator -var firmware_mode=$($attempt.Firmware) -var boot_strategy=$($attempt.Boot) -var winrm_timeout=$($attempt.Timeout) -var headless=$packerHeadless -var efi_firmware_code=$efiCode -var efi_firmware_vars=$efiVars -var disk_size=${DiskGib}G -var output_directory=$tmpOutput ."
                }
            } else {
                if ($DebugHeadful) {
                    Write-Information "vm-setup: [dry-run] cd $packerDir; packer build -var windows_iso=$WindowsIso -var accelerator=$Accelerator -var firmware_mode=$($attempt.Firmware) -var boot_strategy=$($attempt.Boot) -var winrm_timeout=$($attempt.Timeout) -var headless=$packerHeadless -var display_backend=$packerDisplayBackend -var disk_size=${DiskGib}G -var output_directory=$tmpOutput ."
                } else {
                    Write-Information "vm-setup: [dry-run] cd $packerDir; packer build -var windows_iso=$WindowsIso -var accelerator=$Accelerator -var firmware_mode=$($attempt.Firmware) -var boot_strategy=$($attempt.Boot) -var winrm_timeout=$($attempt.Timeout) -var headless=$packerHeadless -var disk_size=${DiskGib}G -var output_directory=$tmpOutput ."
                }
            }
        }
        return
    }

    function Test-WindowsWinRmPortReady {
        param(
            [int]$Port = 5985
        )

        $listeners = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        if (-not $listeners) {
            return $true
        }

        $stalePids = @()
        $nonStalePids = @()
        foreach ($listener in $listeners) {
            $listenerPid = [int]$listener.OwningProcess
            $process = Get-Process -Id $listenerPid -ErrorAction SilentlyContinue
            $name = if ($process) { $process.ProcessName } else { '' }
            if ($name -match '^(qemu-system-x86_64|packer|packer-plugin-qemu)') {
                $stalePids += $listenerPid
            } else {
                $nonStalePids += $listenerPid
            }
        }

        if ($stalePids.Count -gt 0) {
            $stalePids = $stalePids | Sort-Object -Unique
            Write-Warning "vm-setup: detected stale Windows builder listener(s) on tcp/$Port; terminating pid(s): $($stalePids -join ', ')"
            foreach ($stalePid in $stalePids) {
                Stop-Process -Id $stalePid -Force -ErrorAction SilentlyContinue
            }
        }

        $remaining = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        if (-not $remaining) {
            return $true
        }

        $remainingPids = ($remaining | Select-Object -ExpandProperty OwningProcess | Sort-Object -Unique)
        Write-Warning "vm-setup: tcp/$Port is still in use by pid(s): $($remainingPids -join ', '); cannot launch QEMU with hostfwd=tcp::5985-:5985"
        return $false
    }

    Push-Location $packerDir
    try {
        & packer init .
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'vm-setup: packer init failed for Windows'
            return
        }
        $buildSucceeded = $false
        $builtTempDir = $null
        foreach ($attempt in $buildAttempts) {
            Write-Information "vm-setup: Windows Packer attempt using firmware_mode=$($attempt.Firmware) boot_strategy=$($attempt.Boot) (winrm_timeout=$($attempt.Timeout))..."

            # WHY: Packer qemu builder requires output_directory to not already exist.
            # Use a fresh temp tree per attempt so a failed try cannot poison the
            # next firmware/boot-strategy combination.
            $attemptTempDir = Join-Path $ImagesDir ('.{0}.{1}.{2}.{3}' -f $VmName, $attempt.Firmware, $attempt.Boot, ([guid]::NewGuid().ToString('N')))
            New-Item -ItemType Directory -Path $attemptTempDir -Force | Out-Null
            $tmpOutput = Join-Path $attemptTempDir 'output'
            $packerLog = Join-Path $attemptTempDir 'packer.log'
            Write-Information "vm-setup: writing Packer debug log for this attempt: $packerLog"

            if (-not (Test-WindowsWinRmPortReady -Port 5985)) {
                Remove-Item $attemptTempDir -Recurse -Force -ErrorAction SilentlyContinue
                Write-Warning 'vm-setup: aborting Windows build attempts because WinRM host port preflight failed'
                return
            }

            $packerArgs = @(
                '-var', "windows_iso=$WindowsIso",
                '-var', "accelerator=$Accelerator",
                '-var', "firmware_mode=$($attempt.Firmware)",
                '-var', "boot_strategy=$($attempt.Boot)",
                '-var', "winrm_timeout=$($attempt.Timeout)",
                '-var', "headless=$packerHeadless",
                '-var', "disk_size=${DiskGib}G",
                '-var', "output_directory=$tmpOutput",
                '.'
            )
            if ($DebugHeadful) {
                $packerArgs = @(
                    '-var', "windows_iso=$WindowsIso",
                    '-var', "accelerator=$Accelerator",
                    '-var', "firmware_mode=$($attempt.Firmware)",
                    '-var', "boot_strategy=$($attempt.Boot)",
                    '-var', "winrm_timeout=$($attempt.Timeout)",
                    '-var', "headless=$packerHeadless",
                    '-var', "display_backend=$packerDisplayBackend",
                    '-var', "disk_size=${DiskGib}G",
                    '-var', "output_directory=$tmpOutput",
                    '.'
                )
            }
            if ($attempt.Firmware -eq 'efi') {
                $packerArgs = @(
                    '-var', "windows_iso=$WindowsIso",
                    '-var', "accelerator=$Accelerator",
                    '-var', "firmware_mode=$($attempt.Firmware)",
                    '-var', "boot_strategy=$($attempt.Boot)",
                    '-var', "winrm_timeout=$($attempt.Timeout)",
                    '-var', "headless=$packerHeadless",
                    '-var', "efi_firmware_code=$efiCode",
                    '-var', "efi_firmware_vars=$efiVars",
                    '-var', "disk_size=${DiskGib}G",
                    '-var', "output_directory=$tmpOutput",
                    '.'
                )
                if ($DebugHeadful) {
                    $packerArgs = @(
                        '-var', "windows_iso=$WindowsIso",
                        '-var', "accelerator=$Accelerator",
                        '-var', "firmware_mode=$($attempt.Firmware)",
                        '-var', "boot_strategy=$($attempt.Boot)",
                        '-var', "winrm_timeout=$($attempt.Timeout)",
                        '-var', "headless=$packerHeadless",
                        '-var', "display_backend=$packerDisplayBackend",
                        '-var', "efi_firmware_code=$efiCode",
                        '-var', "efi_firmware_vars=$efiVars",
                        '-var', "disk_size=${DiskGib}G",
                        '-var', "output_directory=$tmpOutput",
                        '.'
                    )
                }
            }
            $oldPackerLog = $env:PACKER_LOG
            $oldPackerLogPath = $env:PACKER_LOG_PATH
            $env:PACKER_LOG = '1'
            $env:PACKER_LOG_PATH = $packerLog
            & packer build @packerArgs
            $env:PACKER_LOG = $oldPackerLog
            $env:PACKER_LOG_PATH = $oldPackerLogPath
            if ($LASTEXITCODE -eq 0) {
                $buildSucceeded = $true
                $builtTempDir = $attemptTempDir
                break
            }

            if ($LASTEXITCODE -in 130, 143) {
                Write-Warning "vm-setup: Windows Packer attempt cancelled (exit $LASTEXITCODE); aborting retry matrix"
                Remove-Item $attemptTempDir -Recurse -Force -ErrorAction SilentlyContinue
                return
            }

            Write-Warning "vm-setup: packer build attempt failed for firmware_mode=$($attempt.Firmware) boot_strategy=$($attempt.Boot) (exit $LASTEXITCODE); trying next strategy"
            if (Test-Path $packerLog) {
                Write-Warning "vm-setup: last 60 lines from failed Packer log ($packerLog):"
                Get-Content -Path $packerLog -Tail 60 | ForEach-Object { Write-Warning $_ }
            }
            Remove-Item $attemptTempDir -Recurse -Force
        }

        if (-not $buildSucceeded) {
            Write-Warning 'vm-setup: packer build failed for Windows after all boot strategies'
            return
        }
    }
    finally {
        Pop-Location
    }

        $builtImage = Join-Path (Join-Path $builtTempDir 'output') 'windows.qcow2'
    if (-not (Test-Path $builtImage)) {
        Write-Warning "vm-setup: Packer did not produce $builtImage"
        return
    }

        Move-Item $builtImage $outPath
        Remove-Item $builtTempDir -Recurse -Force

    if (-not (Test-Qcow2Image -ImagePath $outPath -ImageLabel 'newly built Windows image')) {
        Write-Warning "vm-setup: Windows image validation failed after build; removing $outPath"
        Remove-Item $outPath -Force
        return
    }

    Write-Information "vm-setup: Windows 11 image ready: $outPath"
}
