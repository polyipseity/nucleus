<#
.SYNOPSIS
  Build VM images (if needed) and provision VMs on Windows.

.DESCRIPTION
  Combines the former Invoke-VMBuild and Invoke-VMSetup into one module.
  Phase 1 (build): builds pre-built QCOW2 images using Packer for each VM
  declared in src\modules\VMs.json, if absent at
  %USERPROFILE%\virtual machines\images\<name>.qcow2.  For NixOS guests on
  Windows, Packer downloads the NixOS ISO automatically (src\vms\nixos\packer.pkr.hcl).
  For Windows 11 guests, a local ISO is required (-WindowsIso).

  Phase 2 (provision): creates QEMU start scripts and places disk images for
  each VM.  Disk images are copied from the built images, eliminating the manual
  OS installation step previously required with empty disks.

  Called by scripts\vm-setup.ps1 (alias: nucleus-vm-setup).
  Not invoked automatically during nucleus apply — run manually when setting
  up a new machine or rebuilding VM images.

  Source:
  - https://developer.hashicorp.com/packer/plugins/builders/qemu
  - https://www.qemu.org/docs/master/system/invocation.html
  - https://github.com/pbatard/Fido

.NOTES
  Environment variables:
    NUCLEUS_HOST                Host identifier for VM selection.
    NUCLEUS_VM_SECRET_OWNER     SOPS identity for VM guest secrets.
    USERNAME                    Current user for secret resolution.
    VM_DIR_OVERRIDE             Optional override for VM storage directory.
    PROCESSOR_ARCHITECTURE      Used for WHPX auto-detection.

  Exit codes:
    This module does not emit exit codes.
#>
function Wait-GuestReady {
  <#
  .SYNOPSIS
    Wait for a QEMU guest to become ready via the guest agent.

  .DESCRIPTION
    Polls the QEMU Guest Agent named pipe (qga-<VmName>) with guest-ping
    commands until the guest responds or the timeout expires.

  .PARAMETER VmName
    Name of the VM whose guest agent pipe to poll.

  .PARAMETER TimeoutSeconds
    Maximum seconds to wait before returning $false. Defaults to 150.

  .OUTPUTS
    System.Boolean.  $true if the guest responded, $false on timeout.

  .EXAMPLE
    Wait-GuestReady -VmName 'nixos-vm' -TimeoutSeconds 120

  .NOTES
    Environment variables:
      (none)    No environment variables used.

    Exit codes:
      This function does not emit exit codes.
  #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$VmName,
        [int]$TimeoutSeconds = 150
    )

    $pipe = "\\.\pipe\qga-$VmName"
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        try {
            $sock = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipe, [System.IO.Pipes.PipeDirection]::InOut)
            $sock.Connect(1000)
            $writer = New-Object System.IO.StreamWriter($sock)
            $reader = New-Object System.IO.StreamReader($sock)
            $writer.WriteLine('{"execute":"guest-ping"}')
            $writer.Flush()
            $response = $reader.ReadLine()
            if ($response -match '"return"\s*:\s*{}') { return $true }
        } catch {
            # Guest ping timeout is expected in retry loop.
        }
        Start-Sleep -Seconds 5
    }
    return $false
}

function Invoke-VMSetup {
  <#
  .SYNOPSIS
    Build VM disk images and provision VMs on Windows.

  .DESCRIPTION
    Orchestrates VM lifecycle: builds pre-built QCOW2 images using Packer
    (Phase 1) and creates QEMU start scripts with disk images (Phase 2).
    Supports NixOS, Windows 11, and macOS guest types.

  .PARAMETER RepoRoot
    Absolute path to the repository root.

  .PARAMETER WindowsIso
    Path to the Windows 11 ISO. Optional when windowsIsoUrl is set in VMs.json;
    the URL is used to auto-download the installer on first run.

  .PARAMETER NixosOnly
    Build and provision only the NixOS guest.

  .PARAMETER WindowsOnly
    Build and provision only the Windows 11 guest.

  .PARAMETER WindowsIsoSource
    Windows installer ISO resolution strategy. Auto: windowsIsoUrl cache/download
    first, then Fido fallback. Url: use only -WindowsIso or windowsIsoUrl (no
    downloader fallback). Fido: use only local cache/Fido when -WindowsIso is omitted.

  .PARAMETER WindowsIsoRetries
    Retry attempts for Windows ISO network downloads.

  .PARAMETER Accelerator
    QEMU accelerator for image builds. Defaults to tcg (always works).
    When tcg is used, auto-detects WHPX (Windows Hypervisor Platform) and
    upgrades to whpx automatically if enabled.

  .PARAMETER Headful
    Run guest image builds headful (headless=false) for interactive debugging
    of installer issues.

  .PARAMETER DryRun
    Print planned actions without modifying any state.

  .EXAMPLE
    Invoke-VMSetup -RepoRoot 'C:\Users\admin\nucleus'

  .EXAMPLE
    Invoke-VMSetup -RepoRoot 'C:\Users\admin\nucleus' -NixosOnly -Headful

  .EXAMPLE
    Invoke-VMSetup -RepoRoot 'C:\Users\admin\nucleus' -WindowsOnly -WindowsIso 'C:\ISOs\Win11_23H2.iso'

  .NOTES
    Environment variables:
      NUCLEUS_HOST                Host identifier for VM selection.
      NUCLEUS_VM_SECRET_OWNER     SOPS identity for VM guest secrets.
      USERNAME                    Current user for secret resolution.
      VM_DIR_OVERRIDE             Optional override for VM storage directory.
      PROCESSOR_ARCHITECTURE      Used for WHPX auto-detection.

    Exit codes:
      This function does not emit exit codes.
  #>
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
        [ValidateSet('auto', 'url', 'fido')]
        [string]$WindowsIsoSource = 'Auto',

        # Retry attempts for Windows ISO network downloads.
        [int]$WindowsIsoRetries = 0,

        # QEMU accelerator for image builds. Defaults to tcg (always works).
        # When tcg is used, Invoke-VMSetup auto-detects WHPX (Windows Hypervisor
        # Platform) and upgrades to whpx automatically if it is enabled.
        # Source: https://developer.hashicorp.com/packer/plugins/builders/qemu
        [string]$Accelerator = 'tcg',

        # Run guest image builds headful (headless=false) for interactive
        # debugging of installer issues.
        [switch]$Headful,

        # Print planned actions without modifying any state.
        [switch]$DryRun,

        # Remove orphaned VM disk images and credential markers.
        [switch]$Gc
    )

    $ErrorActionPreference = 'Stop'

    function Invoke-GcOrphanDisk {
        param([string[]] $ExpectedNames)
        $dirs = @($vmDir, $imagesDir) | Where-Object { Test-Path $_ -PathType Container }
        foreach ($dir in $dirs) {
            foreach ($disk in Get-ChildItem "$dir\*.qcow2" -ErrorAction SilentlyContinue) {
                $name = [System.IO.Path]::GetFileNameWithoutExtension($disk.Name)
                if ($name -notin $ExpectedNames) {
                    Write-Information "vm-setup: GC — removing non-provisioned disk image: $($disk.FullName)"
                    if (-not $DryRun) {
                        Remove-Item -Path $disk.FullName -Force -ErrorAction Continue
                    }
                }
            }
        }
    }

    function Invoke-GcOrphanMarker {
        $dirs = @($vmDir, $imagesDir) | Where-Object { Test-Path $_ -PathType Container }
        foreach ($dir in $dirs) {
            foreach ($marker in Get-ChildItem "$dir\*.vm-guest-credentials-sha256" -ErrorAction SilentlyContinue) {
                $basePath = $marker.FullName -replace '\.vm-guest-credentials-sha256$'
                if (-not (Test-Path $basePath -PathType Leaf)) {
                    Write-Information "vm-setup: GC — removing orphaned credential marker: $($marker.FullName)"
                    if (-not $DryRun) {
                        Remove-Item -Path $marker.FullName -Force -ErrorAction Continue
                    }
                }
            }
        }
    }

    function Get-VMGuestSecretHash {
        param(
            [Parameter(Mandatory)]
            [string]$AccountName,

            [Parameter(Mandatory)]
            [string]$SecretValue
        )

        $hashBytes = [System.Security.Cryptography.SHA256]::HashData(
            [System.Text.Encoding]::UTF8.GetBytes("$AccountName`n$SecretValue")
        )
        return ([System.Convert]::ToHexString($hashBytes)).ToLowerInvariant()
    }

    function Get-VMGuestSecretMarkerPath {
        param(
            [Parameter(Mandatory)]
            [string]$BasePath
        )

        return "${BasePath}.vm-guest-credentials-sha256"
    }

    function Test-VMGuestSecretMarker {
        param(
            [Parameter(Mandatory)]
            [string]$ExpectedHash,

            [Parameter(Mandatory)]
            [string]$MarkerPath
        )

        if (-not (Test-Path -LiteralPath $MarkerPath -PathType Leaf)) {
            return $false
        }

        return ((Get-Content -Path $MarkerPath -Raw).Trim() -eq $ExpectedHash)
    }

    function Resolve-VMGuestCredential {
        param(
            [Parameter(Mandatory)]
            [string]$RepoRoot
        )

        $secretOwner = if (-not [string]::IsNullOrWhiteSpace([string]$env:NUCLEUS_VM_SECRET_OWNER)) {
            [string]$env:NUCLEUS_VM_SECRET_OWNER
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$env:USERNAME)) {
            [string]$env:USERNAME
        } elseif (-not [string]::IsNullOrWhiteSpace([Environment]::UserName)) {
            [Environment]::UserName
        } else {
            throw 'vm-setup: could not determine the per-user VM secret owner (set NUCLEUS_VM_SECRET_OWNER to override).'
        }

        $userRegistryPath = Join-Path $RepoRoot 'src\hosts\Windows\users.json'
        if (-not (Test-Path -LiteralPath $userRegistryPath -PathType Leaf)) {
            throw "vm-setup: users registry not found: $userRegistryPath"
        }

        $userRegistry = Get-Content -Path $userRegistryPath -Raw | ConvertFrom-Json
        $userProperty = $userRegistry.users.PSObject.Properties[$secretOwner]
        if ($null -eq $userProperty -or $null -eq $userProperty.Value) {
            throw "vm-setup: user '$secretOwner' is missing from $userRegistryPath"
        }

        $vmGuestRef = $userProperty.Value.vmGuest
        if ($null -eq $vmGuestRef -or [string]::IsNullOrWhiteSpace([string]$vmGuestRef.usernameSecretKey) -or [string]::IsNullOrWhiteSpace([string]$vmGuestRef.passwordSecretKey)) {
            throw "vm-setup: vmGuest secret-key references are missing for user '$secretOwner' in $userRegistryPath"
        }

        $secretFile = Join-Path $RepoRoot "src\secrets\users-$secretOwner.yml"
        if (-not (Test-Path -LiteralPath $secretFile -PathType Leaf)) {
            throw "vm-setup: per-user VM secret file not found: $secretFile"
        }

        $sopsCommand = Get-Command -Name 'sops.exe' -ErrorAction SilentlyContinue
        if (-not $sopsCommand) {
            $sopsCommand = Get-Command -Name 'sops' -ErrorAction SilentlyContinue
        }
        if (-not $sopsCommand) {
            throw 'vm-setup: sops was not found in PATH; cannot resolve VM guest credentials from SOPS.'
        }

        $secretJsonText = & $sopsCommand.Source --decrypt --output-type json $secretFile
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($secretJsonText -join "`n"))) {
            throw "vm-setup: failed to decrypt per-user VM secret file: $secretFile"
        }

        $secretJson = ($secretJsonText -join "`n") | ConvertFrom-Json
        $guestUsername = [string]$secretJson.($vmGuestRef.usernameSecretKey)
        $guestPassword = [string]$secretJson.($vmGuestRef.passwordSecretKey)
        if ([string]::IsNullOrWhiteSpace($guestUsername) -or [string]::IsNullOrWhiteSpace($guestPassword)) {
            throw "vm-setup: vmGuest secret values are missing in $secretFile for user '$secretOwner'"
        }

        return [PSCustomObject]@{
            Owner = $secretOwner
            AccountName = $guestUsername
            Secret = $guestPassword
            Hash = Get-VMGuestSecretHash -AccountName $guestUsername -SecretValue $guestPassword
        }
    }

    function Test-VMEnabled {
        param(
            [Parameter(Mandatory)]
            $Vm
        )

        if ($Vm.enabled -isnot [bool]) {
            throw "vm-setup: VM '$($Vm.name)' must declare boolean 'enabled' in src\\modules\\VMs.json"
        }

        return [bool]$Vm.enabled
    }

    function Test-VMHostMatch {
        param(
            [Parameter(Mandatory)]
            $Vm
        )

        # NUCLEUS_HOST env var identifies the current host.  The Vm.hosts
        # field (null = all hosts, or a string array of host names) determines
        # whether this VM should run here.
        $nucleusHost = [string]$env:NUCLEUS_HOST
        if ([string]::IsNullOrWhiteSpace($nucleusHost)) {
            $nucleusHost = 'Windows'
        }

        $hosts = $Vm.hosts
        if ($null -eq $hosts -or $hosts.Length -eq 0) {
            return $true  # null/empty means all hosts
        }

        return ($hosts -contains $nucleusHost)
    }

    $manifest = Join-Path $RepoRoot 'src\modules\VMs.json'
    if (-not (Test-Path $manifest)) {
        Write-Information "vm-setup: manifest not found at $manifest; skipping"
        return
    }

    $vmDef     = Get-Content $manifest -Raw | ConvertFrom-Json
    $vmsDir      = Join-Path $RepoRoot 'src\vms'
    $templatesDir = Join-Path $vmsDir 'templates'
    $vmDir       = if ($env:VM_DIR_OVERRIDE) { $env:VM_DIR_OVERRIDE } else { Join-Path $env:USERPROFILE 'virtual machines' }
    $imagesDir   = Join-Path $vmDir 'images'
    try {
        $guestCredential = Resolve-VMGuestCredential -RepoRoot $RepoRoot
    }
    catch {
        Write-Warning $_.Exception.Message
        return
    }

    $guestUsername = $guestCredential.AccountName
    $guestPassword = $guestCredential.Secret
    $guestSecretHash = $guestCredential.Hash

    Write-Information "vm-setup: guest credential policy active (owner=$($guestCredential.Owner), username=$guestUsername, source=SOPS)"

    if (-not $DryRun) {
        New-Item -ItemType Directory -Path $vmDir     -Force | Out-Null
        New-Item -ItemType Directory -Path $imagesDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $vmDir 'scripts') -Force | Out-Null
    } else {
        Write-Information "vm-setup: [dry-run] New-Item Directory $vmDir"
        Write-Information "vm-setup: [dry-run] New-Item Directory $imagesDir"
        Write-Information "vm-setup: [dry-run] New-Item Directory $(Join-Path $vmDir 'scripts')"
    }

    $vmReadmePath = Join-Path $vmDir 'README.md'
    $vmReadmeTemplate = Join-Path $templatesDir 'README.md'
    if ($DryRun) {
        Write-Information "vm-setup: [dry-run] Write VM directory guide: $vmReadmePath"
    } elseif (Test-Path -LiteralPath $vmReadmeTemplate -PathType Leaf) {
        $vmDirShort = $vmDir -replace [regex]::Escape($env:USERPROFILE), '%USERPROFILE%'
        $imagesDirShort = "$vmDirShort\images"
        (Get-Content -Path $vmReadmeTemplate -Raw) `
            -replace '\{\{VM_DIR_DISPLAY\}\}', $vmDirShort `
            -replace '\{\{IMAGES_DIR_DISPLAY\}\}', $imagesDirShort `
            | Set-Content -Path $vmReadmePath -Encoding UTF8
        Write-Information "vm-setup: VM directory guide written: $vmReadmePath (template)"
    } else {
        Write-Warning "vm-setup: README template not found at $vmReadmeTemplate; writing minimal guide"
        @"
# virtual machines

This directory stores VM artifacts managed by `nucleus-vm-setup`.
"@ | Set-Content -Path $vmReadmePath -Encoding UTF8
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

    # Prune orphaned dot-prefixed Packer build temp dirs from the images dir.
    if (Test-Path -LiteralPath $imagesDir -PathType Container) {
        Get-ChildItem -LiteralPath $imagesDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '.*' } |
            ForEach-Object {
                Remove-Item $_.FullName -Recurse -Force
                Write-Information "vm-setup: removing stale temporary build directory: $($_.Name)"
            }
    }

    foreach ($vm in $vmDef.VMs) {
        if (-not (Test-VMEnabled -Vm $vm)) {
            Write-Information "vm-setup: VM '$($vm.name)' is disabled in manifest; skipping"
            continue
        }

        # Apply host-scoping filter.  VMs that list a hosts array that does
        # not include the current NUCLEUS_HOST are skipped.
        if (-not (Test-VMHostMatch -Vm $vm)) {
            Write-Information "vm-setup: VM '$($vm.name)' is not available on host '$env:NUCLEUS_HOST'; skipping"
            continue
        }

        # Apply -NixosOnly / -WindowsOnly filter.
        if ($NixosOnly   -and $vm.type -ne 'NixOS')   { continue }
        if ($WindowsOnly -and $vm.type -ne 'Windows') { continue }

        switch ($vm.type) {
            'NixOS' {
                $diskGib = [long](($vm.diskBytes + 536870912) / 1073741824)
                Invoke-BuildNixosImage -VmName $vm.name -Accelerator $Accelerator `
                    -DiskGib $diskGib `
                    -VmsDir $vmsDir -ImagesDir $imagesDir `
                    -GuestAccountName $guestUsername -GuestSecret $guestPassword `
                    -GuestSecretHash $guestSecretHash `
                    -DryRun:$DryRun
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
                        -GuestAccountName $guestUsername -GuestSecret $guestPassword `
                        -GuestSecretHash $guestSecretHash `
                    -Headful:$Headful `
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

    # Prune stale start scripts so removed VMs leave no orphaned files.
    $scriptsDir = Join-Path $vmDir 'scripts'
    if (Test-Path $scriptsDir) {
        Remove-Item -Path (Join-Path $scriptsDir '*.sh'), (Join-Path $scriptsDir '*.ps1') -Force -ErrorAction SilentlyContinue
    }

    foreach ($vm in $vmDef.VMs) {
        if (-not (Test-VMEnabled -Vm $vm)) {
            Write-Information "vm-setup: VM '$($vm.name)' is disabled in manifest; skipping"
            continue
        }

        # Apply host-scoping filter.  VMs that list a hosts array that does
        # not include the current NUCLEUS_HOST are skipped.
        if (-not (Test-VMHostMatch -Vm $vm)) {
            Write-Information "vm-setup: VM '$($vm.name)' is not available on host '$env:NUCLEUS_HOST'; skipping"
            continue
        }

        # Apply -NixosOnly / -WindowsOnly filter.
        if ($NixosOnly   -and $vm.type -ne 'NixOS')   { continue }
        if ($WindowsOnly -and $vm.type -ne 'Windows') { continue }

        # Convert SI bytes to nearest binary MiB for QEMU -m flag (which
        # interprets bare integers as MiB).
        $ramMib      = [long](($vm.ramBytes + 524288) / 1048576)
        $diskPath    = Join-Path -Path $vmDir -ChildPath "$($vm.name).qcow2"
        $diskCredentialMarker = Get-VMGuestSecretMarkerPath -BasePath $diskPath
        $startScriptPs1 = Join-Path -Path $vmDir -ChildPath "scripts" -AdditionalChildPath "start-$($vm.name).ps1"
        $startScriptSh = Join-Path -Path $vmDir -ChildPath "scripts" -AdditionalChildPath "start-$($vm.name).sh"
        $prebuilt    = Join-Path -Path $imagesDir -ChildPath "$($vm.name).qcow2"

        Write-Information "vm-setup: configuring VM '$($vm.display)'..."

        $prebuiltValid = (Test-Path $prebuilt) -and (Test-Qcow2Image -ImagePath $prebuilt -ImageLabel "pre-built image '$($vm.name)'")

        # Place disk image from pre-built image (empty disk fallback removed).
        if (Test-Path $diskPath) {
            if (Test-Qcow2Image -ImagePath $diskPath -ImageLabel "runtime disk '$($vm.name)'") {
                if (-not (Test-VMGuestSecretMarker -ExpectedHash $guestSecretHash -MarkerPath $diskCredentialMarker)) {
                    if ($prebuiltValid) {
                        Write-Warning "vm-setup: $($vm.type) runtime disk guest credential drift detected for '$($vm.name)'; replacing runtime disk from pre-built image"
                        if (-not $DryRun) {
                            Remove-Item $diskPath -Force
                            Copy-Item $prebuilt $diskPath
                            Set-Content -Path $diskCredentialMarker -Value $guestSecretHash -Encoding UTF8
                        } else {
                            Write-Information "vm-setup: [dry-run] Remove-Item '$diskPath' -Force"
                            Write-Information "vm-setup: [dry-run] Copy-Item '$prebuilt' '$diskPath'"
                            Write-Information "vm-setup: [dry-run] Set-Content '$diskCredentialMarker' '$guestSecretHash'"
                        }
                    } else {
                        Write-Warning "vm-setup: $($vm.type) runtime disk credential drift detected but no valid pre-built image exists for '$($vm.name)'; skipping"
                        continue
                    }
                } else {
                    Write-Information "vm-setup: disk already exists: $diskPath"
                }
            } elseif ($prebuiltValid) {
                Write-Warning "vm-setup: existing runtime disk is invalid; replacing with pre-built image: $diskPath"
                if (-not $DryRun) {
                    Remove-Item $diskPath -Force
                    Copy-Item $prebuilt $diskPath
                    Set-Content -Path $diskCredentialMarker -Value $guestSecretHash -Encoding UTF8
                } else {
                    Write-Information "vm-setup: [dry-run] Remove-Item '$diskPath' -Force"
                    Write-Information "vm-setup: [dry-run] Copy-Item '$prebuilt' '$diskPath'"
                    Write-Information "vm-setup: [dry-run] Set-Content '$diskCredentialMarker' '$guestSecretHash'"
                }
            } else {
                Write-Warning "vm-setup: runtime disk is invalid and no valid pre-built image exists for '$($vm.name)'; skipping"
                continue
            }
        } elseif ($prebuiltValid) {
            Write-Information "vm-setup: using pre-built image: $prebuilt"
            if (-not $DryRun) {
                Copy-Item $prebuilt $diskPath
                Set-Content -Path $diskCredentialMarker -Value $guestSecretHash -Encoding UTF8
            } else {
                Write-Information "vm-setup: [dry-run] Copy-Item '$prebuilt' '$diskPath'"
                Write-Information "vm-setup: [dry-run] Set-Content '$diskCredentialMarker' '$guestSecretHash'"
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
        $startContentPs1Template = Join-Path $templatesDir 'start-windows.ps1'
        if (Test-Path -LiteralPath $startContentPs1Template -PathType Leaf) {
            $ps1Template = Get-Content -Path $startContentPs1Template -Raw
            $startContentPs1 = $ps1Template.Replace('{{QEMU_SYSTEM}}', $qemuSystem)
            $startContentPs1 = $startContentPs1.Replace('{{VM_NAME}}', $vm.name)
            $startContentPs1 = $startContentPs1.Replace('{{VM_DISPLAY}}', $vm.display)
            $startContentPs1 = $startContentPs1.Replace('{{MACHINE}}', $machine)
            $startContentPs1 = $startContentPs1.Replace('{{CPU}}', $cpu)
            $startContentPs1 = $startContentPs1.Replace('{{CPUS}}', [string]$vm.cpus)
            $startContentPs1 = $startContentPs1.Replace('{{RAM_MIB}}', [string]$ramMib)
            $startContentPs1 = $startContentPs1.Replace('{{DISK_PATH}}', $diskPath)
            $startContentPs1 = $startContentPs1.Replace('{{VGA}}', $vga)
            $startContentPs1 = $startContentPs1.Replace('{{DISPLAY_BACKEND}}', $display)
            $startContentPs1 = $startContentPs1.Replace('{{VIRTIOFS_ARGS}}', $virtiofsArgs)
        } else {
            Write-Warning "vm-setup: start-windows.ps1 template not found at $startContentPs1Template; writing minimal script"
            $startContentPs1 = "Write-Host 'start-$($vm.name).ps1 — Start VM $($vm.display)'"
        }

        # Keep .sh start script inline (QEMU invocation for Git Bash/MSYS).
        $startContentSh = @"
#!/usr/bin/env sh
# start-$($vm.name).sh — Start the '$($vm.display)' QEMU virtual machine.
# Generated by Invoke-VMSetup; re-run nucleus-vm-setup to regenerate.

set -eu

# SSH port forwarding (hostfwd) exposes host:2222 → guest:22 for SSH-based provisioning.
# QEMU GA (chardev pipe + virtio-serial) enables guest-agent commands via named pipe.

'$qemuSystem' \
    -name '$($vm.display)' \
    -machine $machine \
    -cpu $cpu \
    -smp $($vm.cpus) \
    -m $ramMib \
    -drive file='$diskPath',format=qcow2,if=virtio \
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \
    -device virtio-net-pci,netdev=net0 \
    -vga $vga \
    -display $display \
    -rtc base=localtime \
    -chardev pipe,id=qga,path=\\.\pipe\qga-$($vm.name) \
    -device virtio-serial \
    -device virtserialport,chardev=qga,name=org.qemu.guest_agent.0 \
    -usb -device usb-tablet
"@

        if ($DryRun) {
            Write-Information "vm-setup: [dry-run] Write start scripts: $startScriptPs1, $startScriptSh"
        } else {
            Set-Content -Path $startScriptPs1 -Value $startContentPs1 -Encoding UTF8
            Set-Content -Path $startScriptSh -Value $startContentSh -Encoding UTF8
            Write-Information "vm-setup: start scripts written: $startScriptPs1, $startScriptSh"
        }

        # NOTE: Configure script generation was removed. Guest-side converge
        # is handled by the guest itself or via manual invocation.

        Write-Information "vm-setup: VM '$($vm.display)' setup complete"
    }

    if ($Gc) {
        Write-Information 'vm-setup: GC — scanning for non-provisioned VM artifacts...'
        $expectedNames = @(
            foreach ($vm in $vmDef.VMs) {
                if ((Test-VMEnabled $vm) -and (Test-VMHostMatch $vm)) {
                    $vm.name
                }
            }
        )
        Invoke-GcOrphanDisk -ExpectedNames $expectedNames
        Invoke-GcOrphanMarker
        Write-Information 'vm-setup: GC — done'
    }

    Write-Information 'vm-setup: Windows VM setup complete'
    Write-Information "vm-setup: Disk images at: $vmDir"
    Write-Information "vm-setup: VM directory guide at: $vmReadmePath"
    Write-Information "vm-setup: Run the generated scripts/start-<name>.ps1 (or scripts/start-<name>.sh) scripts to launch VMs"
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
# (src\vms\nixos\packer.pkr.hcl).
function Invoke-BuildNixosImage {
    [CmdletBinding()]
    param(
        [string]$VmName,
        [string]$Accelerator,
        [int]$DiskGib,
        [string]$VmsDir,
        [string]$ImagesDir,
        [string]$GuestAccountName,
        [string]$GuestSecret,
        [string]$GuestSecretHash,
        [switch]$DryRun
    )

    $outPath = Join-Path $ImagesDir "$VmName.qcow2"
    $credentialMarkerPath = Get-VMGuestSecretMarkerPath -BasePath $outPath
    if (Test-Path $outPath) {
        if (Test-Qcow2Image -ImagePath $outPath -ImageLabel 'existing NixOS image') {
            if (Test-VMGuestSecretMarker -ExpectedHash $GuestSecretHash -MarkerPath $credentialMarkerPath) {
                Write-Information "vm-setup: NixOS image already built for the current guest credentials (username=$GuestAccountName): $outPath"
                return
            }
            Write-Warning "vm-setup: NixOS image guest credential drift detected; rebuilding image: $outPath"
            Remove-Item $outPath -Force
            if (Test-Path $credentialMarkerPath) {
                Remove-Item $credentialMarkerPath -Force
            }
        } else {
            Write-Warning "vm-setup: existing NixOS image is invalid; rebuilding from scratch: $outPath"
            Remove-Item $outPath -Force
        }
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
        Write-Information "vm-setup: [dry-run] cd $packerDir; packer init .; packer build -var accelerator=$Accelerator -var disk_size=${DiskGib}G -var guest_username=$GuestAccountName -var guest_password=<redacted> -var output_directory=$tmpOutput ."
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
            -var "disk_size=${DiskGib}G" `
            -var "guest_username=$GuestAccountName" `
            -var "guest_password=$GuestSecret" `
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
    Set-Content -Path $credentialMarkerPath -Value $GuestSecretHash -Encoding UTF8

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
        [ValidateSet('auto', 'url', 'fido')]
        [string]$WindowsIsoSource = 'Auto',
        [int]$WindowsIsoRetries = 0,
        [string]$Accelerator,
        [string]$VmsDir,
        [string]$ImagesDir,
        [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))))),
        [string]$WindowsEdition = 'Pro',
        [string]$GuestAccountName,
        [string]$GuestSecret,
        [string]$GuestSecretHash,
        [switch]$Headful,
        [switch]$DryRun
    )

    $outPath = Join-Path $ImagesDir "$VmName.qcow2"
    $credentialMarkerPath = Get-VMGuestSecretMarkerPath -BasePath $outPath
    if (Test-Path $outPath) {
        if (Test-Qcow2Image -ImagePath $outPath -ImageLabel 'existing Windows image') {
            if (Test-VMGuestSecretMarker -ExpectedHash $GuestSecretHash -MarkerPath $credentialMarkerPath) {
                Write-Information "vm-setup: Windows image already built for the current guest credentials (username=$GuestAccountName): $outPath"
                return
            }
            Write-Warning "vm-setup: Windows image guest credential drift detected; rebuilding image: $outPath"
        }
        Write-Warning "vm-setup: existing Windows image is invalid; rebuilding from scratch: $outPath"
        Remove-Item $outPath -Force
        if (Test-Path $credentialMarkerPath) {
            Remove-Item $credentialMarkerPath -Force
        }
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

    # WHY: Software emulation (tcg) runs at 2-5% native speed, so Windows PE
    # load + installation + OOBE can take 10-30 real hours.  Use much longer
    # SSH timeouts for tcg compared to hardware-accelerated (whpx) builds.
    # These match the shell script vm-setup.sh build strategy matrix.
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
            @{ Firmware = 'bios'; Boot = 'legacy'; Timeout = '3h' }
        )
    }

    if ($efiCode -and $efiVars) {
        Write-Information "vm-setup: EFI firmware detected ($efiCode, $efiVars) but BIOS-only build policy is active"
    } else {
        Write-Information 'vm-setup: EFI firmware not detected; using BIOS-only build attempts'
    }

    # WHY: Packer HCL bool vars are easiest to pass as explicit true/false
    # strings from wrapper scripts for cross-shell consistency.
    $packerHeadless = if ($Headful) { 'false' } else { 'true' }
    $packerDisplayBackend = ''
    if ($Headful) {
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
    if ($Headful) {
        Write-Information 'vm-setup: debug mode enabled; running Windows Packer build headful (headless=false)'
        Write-Information "vm-setup: using QEMU display backend for debug run: $packerDisplayBackend"
    }

    if ($DryRun) {
        Write-Information "vm-setup: [dry-run] Remove stale temporary output directory if present: $tmpOutput"
        foreach ($attempt in $buildAttempts) {
            if ($attempt.Firmware -eq 'efi') {
                if ($Headful) {
                    Write-Information "vm-setup: [dry-run] cd $packerDir; packer build -var windows_iso=$WindowsIso -var guest_username=$GuestAccountName -var guest_password=<redacted> -var autounattend_path=$(Join-Path $VmsDir 'windows\\Autounattend.xml') -var accelerator=$Accelerator -var firmware_mode=$($attempt.Firmware) -var boot_strategy=$($attempt.Boot) -var ssh_timeout=$($attempt.Timeout) -var headless=$packerHeadless -var display_backend=$packerDisplayBackend -var efi_firmware_code=$efiCode -var efi_firmware_vars=$efiVars -var disk_size=${DiskGib}G -var output_directory=$tmpOutput ."
                } else {
                    Write-Information "vm-setup: [dry-run] cd $packerDir; packer build -var windows_iso=$WindowsIso -var guest_username=$GuestAccountName -var guest_password=<redacted> -var autounattend_path=$(Join-Path $VmsDir 'windows\\Autounattend.xml') -var accelerator=$Accelerator -var firmware_mode=$($attempt.Firmware) -var boot_strategy=$($attempt.Boot) -var ssh_timeout=$($attempt.Timeout) -var headless=$packerHeadless -var efi_firmware_code=$efiCode -var efi_firmware_vars=$efiVars -var disk_size=${DiskGib}G -var output_directory=$tmpOutput ."
                }
            } else {
                if ($Headful) {
                    Write-Information "vm-setup: [dry-run] cd $packerDir; packer build -var windows_iso=$WindowsIso -var guest_username=$GuestAccountName -var guest_password=<redacted> -var autounattend_path=$(Join-Path $VmsDir 'windows\\Autounattend.xml') -var accelerator=$Accelerator -var firmware_mode=$($attempt.Firmware) -var boot_strategy=$($attempt.Boot) -var ssh_timeout=$($attempt.Timeout) -var headless=$packerHeadless -var display_backend=$packerDisplayBackend -var disk_size=${DiskGib}G -var output_directory=$tmpOutput ."
                } else {
                    Write-Information "vm-setup: [dry-run] cd $packerDir; packer build -var windows_iso=$WindowsIso -var guest_username=$GuestAccountName -var guest_password=<redacted> -var autounattend_path=$(Join-Path $VmsDir 'windows\\Autounattend.xml') -var accelerator=$Accelerator -var firmware_mode=$($attempt.Firmware) -var boot_strategy=$($attempt.Boot) -var ssh_timeout=$($attempt.Timeout) -var headless=$packerHeadless -var disk_size=${DiskGib}G -var output_directory=$tmpOutput ."
                }
            }
        }
        return
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
            Write-Information "vm-setup: Windows Packer attempt using firmware_mode=$($attempt.Firmware) boot_strategy=$($attempt.Boot) (ssh_timeout=$($attempt.Timeout))..."

            # WHY: Packer qemu builder requires output_directory to not already exist.
            # Use a fresh temp tree per attempt so a failed try cannot poison the
            # next firmware/boot-strategy combination.
            $attemptTempDir = Join-Path $ImagesDir ('.{0}.{1}.{2}.{3}' -f $VmName, $attempt.Firmware, $attempt.Boot, ([guid]::NewGuid().ToString('N')))
            New-Item -ItemType Directory -Path $attemptTempDir -Force | Out-Null
            $tmpOutput = Join-Path $attemptTempDir 'output'
            $packerLog = Join-Path $attemptTempDir 'packer.log'
            $autounattendTemplate = Join-Path $VmsDir 'windows\Autounattend.xml'
            $autounattendRendered = Join-Path $attemptTempDir 'Autounattend.xml'
            $autounattendContent = Get-Content -Path $autounattendTemplate -Raw
            $autounattendContent = $autounattendContent.Replace('__NUCLEUS_GUEST_USERNAME__', $GuestAccountName)
            $autounattendContent = $autounattendContent.Replace('__NUCLEUS_GUEST_PASSWORD__', $GuestSecret)
            Set-Content -Path $autounattendRendered -Value $autounattendContent -Encoding UTF8
            Write-Information "vm-setup: writing Packer debug log for this attempt: $packerLog"

            $packerArgs = @(
                '-var', "windows_iso=$WindowsIso",
                '-var', "guest_username=$GuestAccountName",
                '-var', "guest_password=$GuestSecret",
                '-var', "autounattend_path=$autounattendRendered",
                '-var', "accelerator=$Accelerator",
                '-var', "firmware_mode=$($attempt.Firmware)",
                '-var', "boot_strategy=$($attempt.Boot)",
                '-var', "ssh_timeout=$($attempt.Timeout)",
                '-var', "headless=$packerHeadless",
                '-var', "disk_size=${DiskGib}G",
                '-var', "output_directory=$tmpOutput",
                '.'
            )
            if ($Headful) {
                $packerArgs = @(
                    '-var', "windows_iso=$WindowsIso",
                    '-var', "guest_username=$GuestAccountName",
                    '-var', "guest_password=$GuestSecret",
                    '-var', "autounattend_path=$autounattendRendered",
                    '-var', "accelerator=$Accelerator",
                    '-var', "firmware_mode=$($attempt.Firmware)",
                    '-var', "boot_strategy=$($attempt.Boot)",
                    '-var', "ssh_timeout=$($attempt.Timeout)",
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
                    '-var', "guest_username=$GuestAccountName",
                    '-var', "guest_password=$GuestSecret",
                    '-var', "autounattend_path=$autounattendRendered",
                    '-var', "accelerator=$Accelerator",
                    '-var', "firmware_mode=$($attempt.Firmware)",
                    '-var', "boot_strategy=$($attempt.Boot)",
                    '-var', "ssh_timeout=$($attempt.Timeout)",
                    '-var', "headless=$packerHeadless",
                    '-var', "efi_firmware_code=$efiCode",
                    '-var', "efi_firmware_vars=$efiVars",
                    '-var', "disk_size=${DiskGib}G",
                    '-var', "output_directory=$tmpOutput",
                    '.'
                )
                if ($Headful) {
                    $packerArgs = @(
                        '-var', "windows_iso=$WindowsIso",
                        '-var', "guest_username=$GuestAccountName",
                        '-var', "guest_password=$GuestSecret",
                        '-var', "autounattend_path=$autounattendRendered",
                        '-var', "accelerator=$Accelerator",
                        '-var', "firmware_mode=$($attempt.Firmware)",
                        '-var', "boot_strategy=$($attempt.Boot)",
                        '-var', "ssh_timeout=$($attempt.Timeout)",
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
        Set-Content -Path $credentialMarkerPath -Value $GuestSecretHash -Encoding UTF8

    if (-not (Test-Qcow2Image -ImagePath $outPath -ImageLabel 'newly built Windows image')) {
        Write-Warning "vm-setup: Windows image validation failed after build; removing $outPath"
        Remove-Item $outPath -Force
        return
    }

    Write-Information "vm-setup: Windows 11 image ready: $outPath"
}
