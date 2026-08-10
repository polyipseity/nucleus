<#
.SYNOPSIS
  Build VM images (if needed) and provision VMs on Windows.

.DESCRIPTION
  Combines the former Invoke-VMBuild and Invoke-VMSetup into one module.
  Phase 1 (build): builds type system QCOW2 images using Packer for each type
  declared in src\modules\VMs.json, if absent at
  %USERPROFILE%\virtual machines\src\<type>\system image.qcow2.  For NixOS guests on
  Windows, Packer downloads the NixOS ISO automatically (src\vms\NixOS\packer.pkr.hcl).
  For Windows 11 guests, a local ISO is required (-WindowsIso).

  Phase 2 (provision): creates QEMU start scripts and provisions the per-VM
  data disk (a qcow2 overlay over the type system image) for each VM,
  eliminating the manual OS installation step previously required with empty
  disks.

  Called by scripts\vm.ps1 (alias: nucleus-vm setup).
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
. (Join-Path $PSScriptRoot 'Get-VMGuestSshPublicKey.ps1')
function Wait-GuestReady {
  <#
  .SYNOPSIS
    Wait for a QEMU guest to become ready via the guest agent.

  .DESCRIPTION
    Polls the QEMU Guest Agent named pipe (qga-<VmId>) with guest-ping
    commands until the guest responds or the timeout expires.

  .PARAMETER VmId
    ID of the VM whose guest agent pipe to poll.

  .PARAMETER TimeoutSeconds
    Maximum seconds to wait before returning $false. Defaults to 150.

  .OUTPUTS
    System.Boolean.  $true if the guest responded, $false on timeout.

  .EXAMPLE
    Wait-GuestReady -VmId 'NixOS' -TimeoutSeconds 120

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
        [string]$VmId,
        [int]$TimeoutSeconds = 150
    )

    $pipe = "\\.\pipe\qga-$VmId"
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
            Write-Debug "Guest ping to $VmId timed out; retrying..."
        }
        Start-Sleep -Seconds 5
    }
    return $false
}

function Get-VMRunningProcessNameList {
    <#
    .SYNOPSIS
      Returns QEMU VM names from live qemu-system* process command lines.
    #>
    $running = [System.Collections.Generic.List[string]]::new()
    # check-suppress:suppression_doc: probe -- no qemu processes may exist; foreach handles empty result.
    foreach ($proc in Get-CimInstance Win32_Process -Filter "Name LIKE 'qemu-system%'" -ErrorAction SilentlyContinue) {
        if ($proc.CommandLine -match '-name\s+(\S+)') {
            $name = $Matches[1]
            if (-not $running.Contains($name)) {
                $running.Add($name)
            }
        }
    }
    return $running.ToArray()
}

$VM_SYSTEM_IMAGE = 'system image.qcow2'
$VM_PACKER_BUILD_DIR = 'Packer'
$VM_WINDOWS_INSTALLER_ISO = 'installer.iso'
$VM_TYPE_MARKER_BASE = 'system image'

function Get-VMTypeSrcDir {
    param(
        [Parameter(Mandatory)]
        [string]$SrcDir,

        [Parameter(Mandatory)]
        [string]$Type
    )

    return Join-Path $SrcDir $Type
}

function Get-VMSrcPath {
    param(
        [Parameter(Mandatory)]
        [string]$SrcDir,

        [Parameter(Mandatory)]
        [string]$Type,

        [Parameter(Mandatory)]
        [string]$Leaf
    )

    return Join-Path (Get-VMTypeSrcDir -SrcDir $SrcDir -Type $Type) $Leaf
}

function Get-VMSystemImageRelPath {
    param(
        [Parameter(Mandatory)]
        [string]$Type
    )

    return "../src/$Type/$VM_SYSTEM_IMAGE"
}

function Invoke-VMSetup {
  <#
  .SYNOPSIS
    Build VM disk images and provision VMs on Windows.

  .DESCRIPTION
    Orchestrates VM lifecycle: builds type system QCOW2 images using Packer
    (Phase 1) and creates QEMU start scripts with per-VM data disks (Phase 2).
    Supports NixOS, Windows 11, and macOS guest types.

  .PARAMETER RepoRoot
    Absolute path to the repository root.

  .PARAMETER WindowsIso
    Path to the Windows 11 ISO. Optional when Windows.isoUrl is set in VMs.json;
    the URL is used to auto-download the installer on first run.

  .PARAMETER NixOSOnly
    Build and provision only the NixOS guest.

  .PARAMETER WindowsOnly
    Build and provision only the Windows 11 guest.

  .PARAMETER WindowsIsoSource
    Windows installer ISO resolution strategy. Auto: Windows.isoUrl cache/download
    first, then Fido fallback. Url: use only -WindowsIso or Windows.isoUrl (no
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
    Invoke-VMSetup -RepoRoot 'C:\Users\admin\nucleus' -NixOSOnly -Headful

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

        # Path to the Windows 11 ISO. Optional when Windows.isoUrl is set in VMs.json;
        # the URL is used to auto-download the installer on first run.
        # Download from: https://www.microsoft.com/software-download/windows11
        [string]$WindowsIso = '',

        # Build and provision only the NixOS guest.
        [switch]$NixOSOnly,

        # Build and provision only the Windows 11 guest.
        [switch]$WindowsOnly,

        # Windows installer ISO resolution strategy.
        # Auto: Windows.isoUrl cache/download first, then Fido fallback.
        # Url:  use only -WindowsIso or Windows.isoUrl (no downloader fallback).
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
        [switch]$Gc,

        # Also clear disabled VM entries during GC.
        # WHY: default GC preserves disabled entries; only names absent from
        # VMs.json entirely are cleared.  -GcDisabled opts into clearing
        # disabled entries too.
        [switch]$GcDisabled,

        # Also GC orphaned runtime disks in data/ (default GC preserves data/).
        [switch]$GcData,

        # Config-only refresh: descriptors and start/stop scripts.  Skips image
        # build and disk provisioning.  Used by nucleus-vm sync and apply.
        [switch]$SyncOnly
    )

    $ErrorActionPreference = 'Stop'
    $gcDataEnabled = [bool]$GcData

    function Get-VMGcSrcKeepSetForType {
        param(
            [Parameter(Mandatory)]
            [string]$Type,

            [Parameter(Mandatory)]
            [string[]]$ExpectedNames
        )

        $keep = @($VM_SYSTEM_IMAGE)
        foreach ($vm in $vmDef.VMs) {
            if ($vm.type -ne $Type) { continue }
            if ($vm.id -notin $ExpectedNames) { continue }
            if ($null -ne $vm.Android) {
                $keep += [string]$vm.Android.systemImage
                if ($null -ne $vm.Android.gsiUrl) {
                    $keep += [string]$vm.Android.gsiImage
                }
            }
        }
        return @($keep | Sort-Object -Unique)
    }

    function Get-VMGcDataDiskKeepSet {
        param(
            [Parameter(Mandatory)]
            [string[]]$ExpectedNames
        )

        $keep = @()
        foreach ($vm in $vmDef.VMs) {
            if ($vm.id -notin $ExpectedNames) { continue }
            $keep += "$($vm.id).qcow2"
            if ($null -ne $vm.Android) {
                $keep += [string]$vm.Android.userdataImage
            }
        }
        return @($keep | Sort-Object -Unique)
    }

    function Test-VMTypeExpected {
        param(
            [Parameter(Mandatory)]
            [string]$Type,

            [Parameter(Mandatory)]
            [string[]]$ExpectedNames
        )

        foreach ($vm in $vmDef.VMs) {
            if ($vm.type -eq $Type -and $vm.id -in $ExpectedNames) {
                return $true
            }
        }
        return $false
    }

    function Invoke-GcOrphanDisk {
        param([string[]] $ExpectedNames)
        if (Test-Path -LiteralPath $srcDir -PathType Container) {
            foreach ($typeDir in Get-ChildItem -LiteralPath $srcDir -Directory -ErrorAction SilentlyContinue) {
                $keep = @(Get-VMGcSrcKeepSetForType -Type $typeDir.Name -ExpectedNames $ExpectedNames)
                # check-suppress:suppression_doc: probe -- no disk images may exist; foreach handles empty result.
                foreach ($disk in Get-ChildItem -LiteralPath $typeDir.FullName -Filter '*.qcow2' -ErrorAction SilentlyContinue) {
                    if ($disk.Name -notin $keep) {
                        Write-Information "vm-setup: GC — removing non-provisioned disk image: $($disk.FullName)"
                        if (-not $DryRun) {
                            Remove-Item -LiteralPath $disk.FullName -Force -ErrorAction Continue
                        }
                    }
                }
            }
        }

        if ($gcDataEnabled -and (Test-Path -LiteralPath $dataDir -PathType Container)) {
            $keep = @(Get-VMGcDataDiskKeepSet -ExpectedNames $ExpectedNames)
            # check-suppress:suppression_doc: probe -- no disk images may exist; foreach handles empty result.
            foreach ($disk in Get-ChildItem -LiteralPath $dataDir -Filter '*.qcow2' -ErrorAction SilentlyContinue) {
                if ($disk.Name -notin $keep) {
                    Write-Information "vm-setup: GC — removing non-provisioned disk image: $($disk.FullName)"
                    if (-not $DryRun) {
                        Remove-Item -LiteralPath $disk.FullName -Force -ErrorAction Continue
                    }
                }
            }
        }
    }

    function Invoke-GcOrphanMarker {
        param([string[]] $ExpectedNames)

        if (Test-Path -LiteralPath $srcDir -PathType Container) {
            foreach ($typeDir in Get-ChildItem -LiteralPath $srcDir -Directory -ErrorAction SilentlyContinue) {
                if (Test-VMTypeExpected -Type $typeDir.Name -ExpectedNames $ExpectedNames) {
                    continue
                }
                foreach ($markerName in @(
                    "$VM_TYPE_MARKER_BASE.vm-guest-credentials-sha256"
                    "$VM_TYPE_MARKER_BASE.vm-guest-config-sha256"
                )) {
                    $markerPath = Join-Path $typeDir.FullName $markerName
                    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
                        continue
                    }
                    Write-Information "vm-setup: GC — removing orphaned guest marker: $markerPath"
                    if (-not $DryRun) {
                        Remove-Item -LiteralPath $markerPath -Force -ErrorAction Continue
                    }
                }
            }
        }

        if ($gcDataEnabled -and (Test-Path -LiteralPath $dataDir -PathType Container)) {
            # check-suppress:suppression_doc: probe -- no credential markers may exist; foreach handles empty result.
            foreach ($marker in @(
                Get-ChildItem -LiteralPath $dataDir -Filter '*.vm-guest-credentials-sha256' -ErrorAction SilentlyContinue
                Get-ChildItem -LiteralPath $dataDir -Filter '*.vm-guest-config-sha256' -ErrorAction SilentlyContinue
            )) {
                $basePath = $marker.FullName -replace '\.vm-guest-(credentials|config)-sha256$'
                if (-not (Test-Path -LiteralPath $basePath -PathType Leaf)) {
                    Write-Information "vm-setup: GC — removing orphaned credential marker: $($marker.FullName)"
                    if (-not $DryRun) {
                        Remove-Item -LiteralPath $marker.FullName -Force -ErrorAction Continue
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

        $loadUserRegistryScript = Join-Path $RepoRoot 'src\platforms\Windows\modules\Load-UserRegistry.ps1'
        if (-not (Test-Path -LiteralPath $loadUserRegistryScript -PathType Leaf)) {
            throw "vm-setup: user registry loader not found: $loadUserRegistryScript"
        }

        $usersRegistry = & $loadUserRegistryScript -RepoRoot $RepoRoot
        $userRecord = @($usersRegistry.users | Where-Object { $_.name -eq $secretOwner }) | Select-Object -First 1
        if ($null -eq $userRecord) {
            throw "vm-setup: user '$secretOwner' is missing from the user registry"
        }

        $vmGuestRef = $userRecord.vmGuest
        if ($null -eq $vmGuestRef -or [string]::IsNullOrWhiteSpace([string]$vmGuestRef.usernameSecretKey) -or [string]::IsNullOrWhiteSpace([string]$vmGuestRef.passwordSecretKey)) {
            throw "vm-setup: vmGuest secret-key references are missing for user '$secretOwner' in the user registry"
        }

        $secretFile = Join-Path $RepoRoot "src\secrets\users\$secretOwner.yml"
        if (-not (Test-Path -LiteralPath $secretFile -PathType Leaf)) {
            throw "vm-setup: per-user VM secret file not found: $secretFile"
        }

        # check-suppress:suppression_doc: probe whether sops is on PATH; Get-Command throws when absent.
        $sopsCommand = Get-Command -Name 'sops.exe' -ErrorAction SilentlyContinue
        if (-not $sopsCommand) {
            # check-suppress:suppression_doc: fallback probe without .exe suffix.
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
            throw "vm-setup: VM '$($Vm.id)' must declare boolean 'enabled' in src\\modules\\VMs.json"
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

    function Invoke-GcOrphanDescriptor {
        param([string[]] $ExpectedNames)
        if (-not (Test-Path -LiteralPath $vmDir -PathType Container)) { return }
        # check-suppress:suppression_doc: probe -- no VM descriptors may exist; Where-Object handles empty result.
        $orphanDescriptors = Get-ChildItem -LiteralPath $vmDir -File -Filter '*.vm.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -notin $ExpectedNames }
        foreach ($descriptor in $orphanDescriptors) {
            Write-Information "vm-setup: GC — removing orphaned VM descriptor: $($descriptor.FullName)"
            if (-not $DryRun) {
                Remove-Item -LiteralPath $descriptor.FullName -Force
            }
        }
    }

    function Test-VMProcessRunning {
        param(
            [Parameter(Mandatory)]
            [string]$VmId,

            [Parameter(Mandatory)]
            [string]$VmDisplay
        )
        foreach ($name in Get-VMRunningProcessNameList) {
            if ($name -eq $VmId -or $name -eq $VmDisplay) {
                return $true
            }
        }
        return $false
    }

    function Get-VMQcow2VirtualSize {
        param(
            [Parameter(Mandatory)]
            [string]$ImagePath
        )
        if ($null -eq $qemuImg) {
            return [long]0
        }
        $infoJson = & $qemuImg info --output=json $ImagePath 2>$null  # check-suppress:suppression_doc: probe -- image file may not exist or be corrupt; $LASTEXITCODE checked below
        if ($LASTEXITCODE -ne 0 -or -not $infoJson) {
            return [long]0
        }
        try {
            return [long]($infoJson | ConvertFrom-Json).'virtual-size'
        } catch {
            return [long]0
        }
    }

    function Invoke-VMWriteDescriptor {
        param(
            [Parameter(Mandatory)]
            $Vm,

            [Parameter(Mandatory)]
            [string]$RepoRoot
        )

        $descriptorPath = Join-Path $vmDir "$($Vm.id).vm.json"
        if ($DryRun) {
            Write-Information "vm-setup: [dry-run] Write VM descriptor: $descriptorPath"
            return
        }

        # Deterministic hardware identity mirrors vm_mk_uuid / vm_mk_mac_address
        # in scripts/lib/vm.sh (and the MacBook vms.nix mkUuid/mkMacAddress)
        # so descriptors are identical across hosts and platforms.
        $macPrefix = [string]$Vm.macAddressPrefix
        if ([string]::IsNullOrWhiteSpace($macPrefix)) {
            throw "vm-setup: VM '$($Vm.id)' must declare macAddressPrefix in src\modules\VMs.json"
        }

        $sha = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes([string]$Vm.id))
        $hex = [System.Convert]::ToHexString($sha).ToLowerInvariant()
        $uuid = '{0}-{1}-{2}-{3}-{4}' -f $hex.Substring(0, 8), $hex.Substring(8, 4), $hex.Substring(12, 4), $hex.Substring(16, 4), $hex.Substring(20, 12)
        $macSha = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes("mac:$($Vm.id)"))
        $macHex = [System.Convert]::ToHexString($macSha).ToLowerInvariant()
        $mac = '{0}:{1}:{2}:{3}:{4}:{5}' -f $macPrefix, $macHex.Substring(0, 2), $macHex.Substring(2, 2), $macHex.Substring(4, 2), $macHex.Substring(6, 2), $macHex.Substring(8, 2)

        $hostArch = $env:PROCESSOR_ARCHITECTURE
        $arch = switch ($Vm.type) {
            'Android' { 'aarch64' }
            'Windows' { 'x86_64' }
            default { if ($hostArch -eq 'ARM64') { 'aarch64' } else { 'x86_64' } }
        }
        $machine = if ($arch -eq 'x86_64') { 'q35' } else { 'virt' }
        $uefi = ($Vm.type -ne 'Windows' -and $arch -eq 'aarch64')

        if ($Vm.type -eq 'Android') {
            $disks = @(
                @{ role = 'system'; path = "src/$($Vm.type)/$($Vm.Android.systemImage)" }
            )
            if ($null -ne $Vm.Android.gsiUrl) {
                $disks += @{ role = 'gsi'; path = "src/$($Vm.type)/$($Vm.Android.gsiImage)" }
            }
            $disks += @{ role = 'userdata'; path = "data/$($Vm.id).qcow2" }
        } else {
            $disks = @(
                @{ role = 'system'; path = "src/$($Vm.type)/$VM_SYSTEM_IMAGE" },
                @{ role = 'data'; path = "data/$($Vm.id).qcow2" }
            )
        }

        $descriptor = [ordered]@{
            '$schema'    = Join-Path $RepoRoot 'src\modules\vm-descriptor.schema.json'
            id           = [string]$Vm.id
            name         = [string]$Vm.name
            type         = [string]$Vm.type
            enabled      = [bool]$Vm.enabled
            cpus         = [int]$Vm.cpus
            ram          = [string]$Vm.ram
            diskSize     = [string]$Vm.diskSize
            portForwards = @($Vm.portForwards)
            uuid         = $uuid
            mac          = $mac
            arch         = $arch
            machine      = $machine
            uefi         = $uefi
            disks        = @($disks)
            createdBy    = 'nucleus-vm'
        }
        if ($null -ne $Vm.Android) { $descriptor['Android'] = $Vm.Android }
        if ($null -ne $Vm.macOS)   { $descriptor['macOS']   = $Vm.macOS }
        if ($null -ne $Vm.Windows) { $descriptor['Windows'] = $Vm.Windows }

        $descriptor | ConvertTo-Json -Depth 8 | Set-Content -Path $descriptorPath -Encoding UTF8
        Write-Information "vm-setup: VM descriptor written: $descriptorPath"
    }

    function Invoke-VMWriteStartHelper {
        param(
            [Parameter(Mandatory)]
            $Vm,

            [Parameter(Mandatory)]
            [string]$QemuDir,

            [Parameter(Mandatory)]
            [string]$ScriptsDir,

            [Parameter(Mandatory)]
            [string]$TemplatesDir
        )

        if ($Vm.type -eq 'Android') {
            # The Android QEMU start script is shared canonical content
            # (embedded-content policy); render the shared file instead of an
            # embedded copy.
            $androidStartPath = Join-Path $RepoRoot 'src\scripts\vms\start-android-vm.ps1'
            if (-not (Test-Path -LiteralPath $androidStartPath -PathType Leaf)) {
                throw "vm-setup: shared Android VM start script not found: $androidStartPath"
            }
            $ramBytes = ConvertFrom-SizeString $Vm.ram
            $hostFwds = ($Vm.portForwards | ForEach-Object { "hostfwd=tcp::$($_.hostPort)-:$($_.guestPort)" }) -join ','
            $template = Get-Content -Path $androidStartPath -Raw
            $content = $template.Replace('__ANDROID_CPU_COUNT__', [string]$Vm.cpus)
            $content = $content.Replace('__ANDROID_RAM_BYTES__', "${ramBytes}B")
            $content = $content.Replace('__ANDROID_SYSTEM_IMAGE__', [string]$Vm.Android.systemImage)
            $content = $content.Replace('__ANDROID_USERDATA_IMAGE__', [string]$Vm.Android.userdataImage)
            $content = $content.Replace('__ANDROID_GSI_IMAGE__', [string]$Vm.Android.gsiImage)
            $content = $content.Replace('__HOSTFWDS__', $hostFwds)
            $startPs1 = Join-Path $ScriptsDir "start-$($Vm.id).ps1"
            if ($DryRun) {
                Write-Information "vm-setup: [dry-run] Write start script: $startPs1"
            } else {
                Set-Content -Path $startPs1 -Value $content -Encoding UTF8
                Write-Information "vm-setup: start script written: $startPs1"
            }
            return
        }

        $hostArch = $env:PROCESSOR_ARCHITECTURE
        # The QEMU system binary is host-arch based (mirrors the POSIX
        # windows-qemu render); the descriptor arch is type-based.
        $vmArch = if ($hostArch -eq 'ARM64') { 'aarch64' } else { 'x86_64' }
        $qemuSystem = Join-Path $QemuDir "qemu-system-$vmArch.exe"
        $machine = if ($vmArch -eq 'x86_64') { 'q35' } else { 'virt' }
        $cpu = 'host'

        $ramBytes = ConvertFrom-SizeString $Vm.ram
        $hostFwds = ($Vm.portForwards | ForEach-Object { "hostfwd=tcp::$($_.hostPort)-:$($_.guestPort)" }) -join ','
        # Relocatable writable-disk path: data/<id>.qcow2 relative to the VM
        # tree root (the rendered templates cd/Push-Location before QEMU).
        $diskPath = Join-Path 'data' "$($Vm.id).qcow2"

        $display = 'sdl'
        $vga = if ($Vm.type -eq 'Windows') { 'std' } else { 'virtio' }

        # Determine VirtioFS shared directory argument.
        # check-suppress:embedded-content: exception 1 (data-driven/generated content) -- per-VM conditional args
        $virtiofsArgs = ''
        if ($Vm.shareDevDir) {
            $devDir = Join-Path $env:USERPROFILE 'dev'
            # VirtioFS on Windows requires virtiofsd running separately.
            # Add a placeholder reminder; the start script shows how to launch
            # virtiofsd before starting the guest.
            $virtiofsArgs = @"

# To enable ~/dev directory sharing:
# 1. Start virtiofsd in a separate terminal:
#      virtiofsd --socket-path=\\.\pipe\$($Vm.id)-virtiofs --shared-dir="$devDir"
# 2. Then run this script.
# -chardev socket,id=char0,path=\\.\pipe\$($Vm.id)-virtiofs ``
# -device vhost-user-fs-pci,chardev=char0,tag=dev ``
# -object memory-backend-file,id=mem,size=${ramBytes}B,mem-path=/dev/shm,share=on ``
# -numa node,memdev=mem
"@
        }

        $startPs1Path = Join-Path $ScriptsDir "start-$($Vm.id).ps1"
        $startShPath = Join-Path $ScriptsDir "start-$($Vm.id).sh"
        $ps1TemplatePath = Join-Path $TemplatesDir 'start-windows.ps1'
        $shTemplatePath = Join-Path $TemplatesDir 'start-windows-host.sh'
        if (Test-Path -LiteralPath $ps1TemplatePath -PathType Leaf) {
            $ps1Template = Get-Content -Path $ps1TemplatePath -Raw
            $startContentPs1 = $ps1Template.Replace('__QEMU_SYSTEM__', $qemuSystem)
            $startContentPs1 = $startContentPs1.Replace('__VM_ID__', $Vm.id)
            $startContentPs1 = $startContentPs1.Replace('__VM_DISPLAY__', $Vm.name)
            $startContentPs1 = $startContentPs1.Replace('__MACHINE__', $machine)
            $startContentPs1 = $startContentPs1.Replace('__CPU__', $cpu)
            $startContentPs1 = $startContentPs1.Replace('__CPUS__', [string]$Vm.cpus)
            $startContentPs1 = $startContentPs1.Replace('__RAM_BYTES__', [string]$ramBytes)
            $startContentPs1 = $startContentPs1.Replace('__DISK_PATH__', $diskPath)
            $startContentPs1 = $startContentPs1.Replace('__HOSTFWDS__', $hostFwds)
            $startContentPs1 = $startContentPs1.Replace('__VGA__', $vga)
            $startContentPs1 = $startContentPs1.Replace('__DISPLAY_BACKEND__', $display)
            $startContentPs1 = $startContentPs1.Replace('__VIRTIOFS_ARGS__', $virtiofsArgs)
        } else {
            Write-Warning "vm-setup: start-windows.ps1 template not found at $ps1TemplatePath; writing minimal script"
            $startContentPs1 = "Write-Host 'start-$($Vm.id).ps1 — Start VM $($Vm.name)'"
        }
        if (Test-Path -LiteralPath $shTemplatePath -PathType Leaf) {
            $shTemplate = Get-Content -Path $shTemplatePath -Raw
            $startContentSh = $shTemplate.Replace('__QEMU_SYSTEM__', $qemuSystem)
            $startContentSh = $startContentSh.Replace('__VM_ID__', $Vm.id)
            $startContentSh = $startContentSh.Replace('__VM_DISPLAY__', $Vm.name)
            $startContentSh = $startContentSh.Replace('__MACHINE__', $machine)
            $startContentSh = $startContentSh.Replace('__CPU__', $cpu)
            $startContentSh = $startContentSh.Replace('__CPUS__', [string]$Vm.cpus)
            $startContentSh = $startContentSh.Replace('__RAM_BYTES__', [string]$ramBytes)
            $startContentSh = $startContentSh.Replace('__DISK_PATH__', $diskPath)
            $startContentSh = $startContentSh.Replace('__HOSTFWDS__', $hostFwds)
            $startContentSh = $startContentSh.Replace('__VGA__', $vga)
            $startContentSh = $startContentSh.Replace('__DISPLAY_BACKEND__', $display)
        } else {
            Write-Warning "vm-setup: start-windows-host.sh template not found at $shTemplatePath; writing minimal script"
            $startContentSh = "#!/bin/sh`n# start-$($Vm.id).sh — Start VM $($Vm.name)"
        }

        if ($DryRun) {
            Write-Information "vm-setup: [dry-run] Write start scripts: $startPs1Path, $startShPath"
        } else {
            Set-Content -Path $startPs1Path -Value $startContentPs1 -Encoding UTF8
            Set-Content -Path $startShPath -Value $startContentSh -Encoding UTF8
            Write-Information "vm-setup: start scripts written: $startPs1Path, $startShPath"
        }
    }

    function Invoke-VMWriteStopHelper {
        param(
            [Parameter(Mandatory)]
            $Vm,

            [Parameter(Mandatory)]
            [string]$ScriptsDir,

            [Parameter(Mandatory)]
            [string]$TemplatesDir
        )

        $stopPs1 = Join-Path $ScriptsDir "stop-$($Vm.id).ps1"
        $stopTemplatePath = Join-Path $TemplatesDir 'stop-host.ps1'
        if (-not (Test-Path -LiteralPath $stopTemplatePath -PathType Leaf)) {
            Write-Warning "vm-setup: stop-host.ps1 template not found at $stopTemplatePath; skipping stop script"
            return
        }
        if ($DryRun) {
            Write-Information "vm-setup: [dry-run] Write stop script: $stopPs1"
            return
        }
        $template = Get-Content -Path $stopTemplatePath -Raw
        $content = $template.Replace('__HOST_KIND__', 'windows-qemu').Replace('__VM_ID__', $Vm.id)
        Set-Content -Path $stopPs1 -Value $content -Encoding UTF8
        Write-Information "vm-setup: stop script written: $stopPs1"
    }

    function Invoke-VMWritePackUnpackHelper {
        param(
            [Parameter(Mandatory)]
            [string]$ScriptsDir
        )

        if ($DryRun) {
            Write-Information "vm-setup: [dry-run] Write pack/unpack helper scripts under $ScriptsDir"
            return
        }
        New-Item -ItemType Directory -Path $ScriptsDir -Force > $null
        $packSh = "#!/usr/bin/env bash`nset -euo pipefail`nexec nucleus-vm pack `"`$@`"`n"
        $unpackSh = "#!/usr/bin/env bash`nset -euo pipefail`nexec nucleus-vm unpack `"`$@`"`n"
        $packPs1 = "# Generated by nucleus-vm setup — pack.ps1. Delegates to nucleus-vm pack.`n& nucleus-vm pack @args`nexit `$LASTEXITCODE`n"
        $unpackPs1 = "# Generated by nucleus-vm setup — unpack.ps1. Delegates to nucleus-vm unpack.`n& nucleus-vm unpack @args`nexit `$LASTEXITCODE`n"
        Set-Content -Path (Join-Path $ScriptsDir 'pack.sh') -Value $packSh -Encoding UTF8
        Set-Content -Path (Join-Path $ScriptsDir 'unpack.sh') -Value $unpackSh -Encoding UTF8
        Set-Content -Path (Join-Path $ScriptsDir 'pack.ps1') -Value $packPs1 -Encoding UTF8
        Set-Content -Path (Join-Path $ScriptsDir 'unpack.ps1') -Value $unpackPs1 -Encoding UTF8
        Write-Information "vm-setup: pack/unpack helper scripts written: $ScriptsDir"
    }

    . (Join-Path -Path $RepoRoot -ChildPath 'src\platforms\Windows\modules\SizeStrings.ps1')

    $manifest = Join-Path $RepoRoot 'src\modules\VMs.json'
    if (-not (Test-Path $manifest)) {
        Write-Information "vm-setup: manifest not found at $manifest; skipping"
        return
    }

    $vmDef     = Get-Content $manifest -Raw | ConvertFrom-Json
    $vmsDir      = Join-Path $RepoRoot 'src\vms'
    $templatesDir = Join-Path $vmsDir 'templates'
    $vmDir       = if ($env:VM_DIR_OVERRIDE) { $env:VM_DIR_OVERRIDE } else { Join-Path $env:USERPROFILE 'virtual machines' }
    $srcDir      = Join-Path $vmDir 'src'
    $dataDir     = Join-Path $vmDir 'data'
    try {
        $guestCredential = Resolve-VMGuestCredential -RepoRoot $RepoRoot
    }
    catch {
        if ($SyncOnly) {
            Write-Warning $_.Exception.Message
            Write-Warning 'vm-sync: proceeding without guest credentials'
            $guestCredential = $null
        } else {
            Write-Warning $_.Exception.Message
            return
        }
    }

    if ($null -ne $guestCredential) {
        $guestUsername = $guestCredential.AccountName
        $guestPassword = $guestCredential.Secret
        $guestSecretHash = $guestCredential.Hash

        # Export SSH public key for NixOS guest provisioning (guest.nix uses it for authorized_keys).
        $sshPublicKey = Get-VMGuestSshPublicKey -RepoRoot $RepoRoot -Username $guestCredential.AccountName
        if ($null -ne $sshPublicKey) {
            $env:NUCLEUS_VM_GUEST_SSH_PUBLIC_KEY = $sshPublicKey
            Write-Information "vm-setup: SSH public key exported for NixOS guest provisioning"
        } else {
            Write-Warning "vm-setup: no SSH public key found; NixOS guest will use password auth only"
        }

        Write-Information "vm-setup: guest credential policy active (owner=$($guestCredential.Owner), username=$guestUsername, source=SOPS)"
    }

    if (-not $DryRun) {
        New-Item -ItemType Directory -Path $vmDir     -Force > $null
        New-Item -ItemType Directory -Path $srcDir  -Force > $null
        New-Item -ItemType Directory -Path $dataDir   -Force > $null
        foreach ($vmType in @($vmDef.VMs | ForEach-Object { $_.type } | Sort-Object -Unique)) {
            New-Item -ItemType Directory -Path (Get-VMTypeSrcDir -SrcDir $srcDir -Type $vmType) -Force > $null
        }
        New-Item -ItemType Directory -Path (Join-Path $vmDir 'scripts') -Force > $null
    } else {
        Write-Information "vm-setup: [dry-run] New-Item Directory $vmDir"
        Write-Information "vm-setup: [dry-run] New-Item Directory $srcDir"
        Write-Information "vm-setup: [dry-run] New-Item Directory $dataDir"
        foreach ($vmType in @($vmDef.VMs | ForEach-Object { $_.type } | Sort-Object -Unique)) {
            Write-Information "vm-setup: [dry-run] New-Item Directory $(Get-VMTypeSrcDir -SrcDir $srcDir -Type $vmType)"
        }
        Write-Information "vm-setup: [dry-run] New-Item Directory $(Join-Path $vmDir 'scripts')"
    }

    $vmReadmePath = Join-Path $vmDir 'README.md'
    $vmReadmeTemplate = Join-Path $templatesDir 'README.md'
    if ($DryRun) {
        Write-Information "vm-setup: [dry-run] Write VM directory guide: $vmReadmePath"
    } elseif (Test-Path -LiteralPath $vmReadmeTemplate -PathType Leaf) {
        $vmDirShort = $vmDir -replace [regex]::Escape($env:USERPROFILE), '%USERPROFILE%'
        (Get-Content -Path $vmReadmeTemplate -Raw) `
            -replace '__VM_DIR_DISPLAY__', $vmDirShort `
            | Set-Content -Path $vmReadmePath -Encoding UTF8
        Write-Information "vm-setup: VM directory guide written: $vmReadmePath (template)"
    } else {
        Write-Warning "vm-setup: README template not found at $vmReadmeTemplate; writing minimal guide"
        # check-suppress:embedded-content: exception 2 (trivial static content) -- README fallback under 10 lines
        @"
# virtual machines

This directory stores VM artifacts managed by `nucleus-vm setup`.
"@ | Set-Content -Path $vmReadmePath -Encoding UTF8
    }

    # Auto-detect WHPX when the user has not specified a non-default accelerator.
    # WHPX (Windows Hypervisor Platform) is significantly faster than tcg software
    # emulation and should be used when available.
    # Source: https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/user-guide/nested-virtualization
    if (-not $SyncOnly -and $Accelerator -eq 'tcg') {
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
    # Config sync — descriptors and start/stop scripts (all manifest guests).
    # Runs before image build; shared with nucleus-vm sync (-SyncOnly).
    # -------------------------------------------------------------------------

    $scoopQemuDir = Join-Path $env:USERPROFILE 'scoop\apps\qemu\current'
    $qemuImg = Join-Path $scoopQemuDir 'qemu-img.exe'
    if (-not (Test-Path $qemuImg)) {
        # check-suppress:suppression_doc: probe whether qemu-img is on PATH; Get-Command throws when absent.
        $qemuImgInPath = Get-Command qemu-img -ErrorAction SilentlyContinue
        if ($qemuImgInPath) {
            $qemuImg = $qemuImgInPath.Source
        } else {
            $qemuImg = $null
        }
    }

    $scriptsDir = Join-Path $vmDir 'scripts'
    if (Test-Path $scriptsDir) {
        $staleScripts = @(
            Get-ChildItem -LiteralPath $scriptsDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^(start|stop)-.+\.(sh|ps1)$' }
        )
        foreach ($stale in $staleScripts) {
            if ($DryRun) {
                Write-Information "vm-sync: [dry-run] Remove-Item '$($stale.FullName)' -Force"
            } else {
                Remove-Item -LiteralPath $stale.FullName -Force
            }
        }
    }

    if (-not $DryRun) {
        New-Item -ItemType Directory -Path $scriptsDir -Force > $null
    }

    foreach ($vm in $vmDef.VMs) {
        Invoke-VMWriteDescriptor -Vm $vm -RepoRoot $RepoRoot
        Invoke-VMWriteStartHelper -Vm $vm -QemuDir $scoopQemuDir -ScriptsDir $scriptsDir -TemplatesDir $templatesDir
        Invoke-VMWriteStopHelper -Vm $vm -ScriptsDir $scriptsDir -TemplatesDir $templatesDir
        Write-Information "vm-sync: VM '$($vm.name)' scripts ready"
    }

    Invoke-VMWritePackUnpackHelper -ScriptsDir $scriptsDir

    foreach ($vm in $vmDef.VMs) {
        if (-not (Test-VMEnabled -Vm $vm)) { continue }
        if (-not (Test-VMHostMatch -Vm $vm)) { continue }
        if (Test-VMProcessRunning -VmId $vm.id -VmDisplay $vm.name) {
            Write-Warning "vm-sync: VM '$($vm.id)' is running; stop and restart it for config changes (e.g. port forwards) to take effect"
        }
    }

    if ($SyncOnly) {
        Write-Information 'vm-sync: Windows VM config refresh complete'
        return
    }

    # -------------------------------------------------------------------------
    # Phase 1 — Build images (if absent)
    # -------------------------------------------------------------------------

    # Prune orphaned dot-prefixed Packer build temp dirs under src/<type>/.
    if (Test-Path -LiteralPath $srcDir -PathType Container) {
        foreach ($typeDir in Get-ChildItem -LiteralPath $srcDir -Directory -ErrorAction SilentlyContinue) {
            # check-suppress:suppression_doc: probe -- no stale temp directories may exist; Where-Object handles empty result.
            Get-ChildItem -LiteralPath $typeDir.FullName -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like '.*' } |
                ForEach-Object {
                    Remove-Item $_.FullName -Recurse -Force
                    Write-Information "vm-setup: removing stale temporary build directory: $($typeDir.Name)/$($_.Name)"
                }
        }
    }

    foreach ($vm in $vmDef.VMs) {
        if (-not (Test-VMEnabled -Vm $vm)) {
            Write-Information "vm-setup: VM '$($vm.id)' is disabled in manifest; skipping"
            continue
        }

        # Apply host-scoping filter.  VMs that list a hosts array that does
        # not include the current NUCLEUS_HOST are skipped.
        if (-not (Test-VMHostMatch -Vm $vm)) {
            Write-Information "vm-setup: VM '$($vm.id)' is not available on host '$env:NUCLEUS_HOST'; skipping"
            continue
        }

        # Apply -NixOSOnly / -WindowsOnly filter.
        if ($NixOSOnly   -and $vm.type -ne 'NixOS')   { continue }
        if ($WindowsOnly -and $vm.type -ne 'Windows') { continue }

        switch ($vm.type) {
            'NixOS' {
                $diskBytes = ConvertFrom-SizeString $vm.diskSize
                $minSizeBytes = ConvertFrom-SizeString $vm.minImageSize
                $env:NUCLEUS_VM_GUEST_HOSTNAME = $vm.hostname
                Invoke-BuildNixosImage -VmName $vm.id -Accelerator $Accelerator `
                    -DiskBytes $diskBytes -MinSize $minSizeBytes `
                    -VmsDir $vmsDir -SrcDir $srcDir `
                    -GuestAccountName $guestUsername -GuestSecret $guestPassword `
                    -GuestSecretHash $guestSecretHash `
                    -DryRun:$DryRun
            }
            'Windows' {
                $diskBytes = ConvertFrom-SizeString $vm.diskSize
                $minSizeBytes = ConvertFrom-SizeString $vm.minImageSize
                $hostFwds = ($vm.portForwards | ForEach-Object { "hostfwd=tcp::$($_.hostPort)-:$($_.guestPort)" }) -join ','
                $isoUrl = if ($null -ne $vm.Windows.isoUrl) { [string]$vm.Windows.isoUrl } else { '' }
                Invoke-BuildWindowsImage -VmName $vm.id -DiskBytes $diskBytes `
                    -WindowsIso $WindowsIso -WindowsIsoUrl $isoUrl `
                    -WindowsIsoSource $WindowsIsoSource `
                    -WindowsIsoRetries $WindowsIsoRetries `
                    -RepoRoot $RepoRoot `
                    -WindowsEdition $vm.Windows.edition `
                    -Accelerator $Accelerator `
                        -GuestAccountName $guestUsername -GuestSecret $guestPassword `
                        -GuestSecretHash $guestSecretHash `
                    -MinSize $minSizeBytes -GuestHostname $vm.hostname -HostFwds $hostFwds `
                    -Headful:$Headful `
                    -VmsDir $vmsDir -SrcDir $srcDir -DryRun:$DryRun
            }
            'Android' {
                # Android system/GSI images are fetched from the manifest
                # Android group (gsiUrl) and cannot be automated here; the
                # writable data/<id>.qcow2 userdata disk is provisioned in
                # Phase 2.
                Write-Information "vm-setup: Android image must be obtained from the manifest Android group (gsiUrl); place system/GSI images under $(Get-VMTypeSrcDir -SrcDir $srcDir -Type 'Android')"
            }
            'macOS' {
                Write-Information "vm-setup: macOS image must be obtained manually (licensing restricts automation)"
            }
            default {
                Write-Information "vm-setup: skipping build for '$($vm.id)' (unsupported type: $($vm.type))"
            }
        }
    }

    # -------------------------------------------------------------------------
    # Phase 2 — Provision VMs (disk provisioning)
    # -------------------------------------------------------------------------

    if (-not $DryRun) {
        New-Item -ItemType Directory -Path $dataDir -Force > $null
    }

    foreach ($vm in $vmDef.VMs) {
        if (-not (Test-VMEnabled -Vm $vm)) {
            Write-Information "vm-setup: VM '$($vm.id)' is disabled in manifest; skipping"
            continue
        }

        # Apply host-scoping filter.  VMs that list a hosts array that does
        # not include the current NUCLEUS_HOST are skipped.
        if (-not (Test-VMHostMatch -Vm $vm)) {
            Write-Information "vm-setup: VM '$($vm.id)' is not available on host '$env:NUCLEUS_HOST'; skipping"
            continue
        }

        # Apply -NixOSOnly / -WindowsOnly filter.
        if ($NixOSOnly   -and $vm.type -ne 'NixOS')   { continue }
        if ($WindowsOnly -and $vm.type -ne 'Windows') { continue }

        # Pass A — disk provisioning (enabled-only, mirroring
        # vm_ensure_data_disk): the writable data disk is a qcow2 overlay over
        # src/<type>/system image.qcow2 created with a tree-root-relative
        # backing path.  Android's userdata disk is a standalone qcow2 (no
        # base).  Data-preservation invariants: an existing valid data disk is
        # never recreated/truncated during setup; markers missing on an
        # existing disk are adopted; credential drift warns for in-place
        # injection only (never auto-wipes).
        Write-Information "vm-setup: configuring VM '$($vm.name)'..."

        $minSizeBytes = ConvertFrom-SizeString $vm.minImageSize
        $systemImage = Get-VMSrcPath -SrcDir $srcDir -Type $vm.type -Leaf $VM_SYSTEM_IMAGE
        $systemImageValid = (Test-Path $systemImage) -and (Test-Qcow2Image -ImagePath $systemImage -ImageLabel "system image '$($vm.type)'" -MinBytes $minSizeBytes)

        if ($vm.type -eq 'Android') {
            # Android userdata: standalone writable qcow2 created at the
            # manifest disk size (system/GSI images are read-only payload
            # under src/<type>/).  Mirrors the POSIX Android provisioning branch.
            $userdataPath = Join-Path -Path $dataDir -ChildPath "$($vm.id).qcow2"
            if (-not (Test-Path -LiteralPath $userdataPath -PathType Leaf)) {
                $diskBytes = ConvertFrom-SizeString $vm.diskSize
                Write-Information "vm-setup: Android userdata disk missing; creating $userdataPath"
                if (-not $DryRun) {
                    if ($null -eq $qemuImg) {
                        Write-Warning "vm-setup: qemu-img not found; cannot create Android userdata disk for '$($vm.id)'"
                    } else {
                        & $qemuImg create -f qcow2 $userdataPath $diskBytes
                        if ($LASTEXITCODE -ne 0) {
                            Write-Warning "vm-setup: qemu-img create failed for Android userdata disk: $userdataPath"
                        }
                    }
                } else {
                    Write-Information "vm-setup: [dry-run] qemu-img create -f qcow2 '$userdataPath' '$diskBytes'"
                }
            } else {
                Write-Information "vm-setup: Android userdata disk already exists: $userdataPath"
            }
            continue
        }

        $diskPath = Join-Path -Path $dataDir -ChildPath "$($vm.id).qcow2"
        $backingRel = Get-VMSystemImageRelPath -Type $vm.type
        $diskCredentialMarker = Get-VMGuestSecretMarkerPath -BasePath $diskPath

        # Data disk provisioning (mirrors vm_ensure_data_disk):
        # - data disk valid: keep it; adopt markers when absent; on credential
        #   drift warn for in-place injection (never recreate)
        # - data disk invalid: keep it and warn (reset is the destructive path)
        # - data disk absent: create as an overlay on the system image
        if (Test-Path $diskPath) {
            if (Test-Qcow2Image -ImagePath $diskPath -ImageLabel "data disk '$($vm.id)'" -MinBytes $minSizeBytes) {
                Write-Information "vm-setup: data disk already exists: $diskPath"
                if (-not (Test-VMGuestSecretMarker -ExpectedHash $guestSecretHash -MarkerPath $diskCredentialMarker)) {
                    if (Test-Path $diskCredentialMarker) {
                        if (Test-VMProcessRunning -VmId $vm.id -VmDisplay $vm.name) {
                            Write-Warning "vm-setup: VM '$($vm.id)' is running; skipping in-place injection (applies on next setup)"
                        } else {
                            Write-Warning "vm-setup: $($vm.type) data disk guest credential drift detected for '$($vm.id)'; run 'nucleus-vm inject $($vm.id)' to re-inject in place (data disk preserved)"
                        }
                    } else {
                        Write-Information "vm-setup: adopting missing provision marker for existing data disk '$($vm.id)'"
                        if (-not $DryRun) {
                            Set-Content -Path $diskCredentialMarker -Value $guestSecretHash -Encoding UTF8
                        } else {
                            Write-Information "vm-setup: [dry-run] Set-Content '$diskCredentialMarker' '$guestSecretHash'"
                        }
                    }
                }
            } else {
                Write-Warning "vm-setup: data disk is invalid for '$($vm.id)': $diskPath; run 'nucleus-vm reset $($vm.id)' to recreate it (data preserved)"
            }
        } elseif ($systemImageValid) {
            Write-Information "vm-setup: using system image: $systemImage"
            if (-not $DryRun) {
                if ($null -eq $qemuImg) {
                    Write-Warning "vm-setup: qemu-img not found; cannot create data disk for '$($vm.id)'"
                } else {
                    & $qemuImg create -f qcow2 -b $backingRel -F qcow2 $diskPath
                    if ($LASTEXITCODE -ne 0) {
                        Write-Warning "vm-setup: qemu-img create failed for data disk: $diskPath"
                    }
                }
                Set-Content -Path $diskCredentialMarker -Value $guestSecretHash -Encoding UTF8
            } else {
                Write-Information "vm-setup: [dry-run] qemu-img create -f qcow2 -b '$backingRel' -F qcow2 '$diskPath'"
                Write-Information "vm-setup: [dry-run] Set-Content '$diskCredentialMarker' '$guestSecretHash'"
            }
        } else {
            Write-Warning "vm-setup: system image not found or invalid for '$($vm.id)': $systemImage; skipping"
        }

        # Grow-only auto-grow: bring the data disk's virtual size up to the
        # manifest disk size (never shrink).  Mirrors vm_ensure_data_disk.
        $diskBytes = ConvertFrom-SizeString $vm.diskSize
        $dataDiskSize = Get-VMQcow2VirtualSize -ImagePath $diskPath
        if ($dataDiskSize -gt 0 -and $diskBytes -gt $dataDiskSize) {
            Write-Information "vm-setup: growing data disk '$($vm.id)' from $dataDiskSize to $diskBytes bytes (grow-only)"
            if (-not $DryRun) {
                if ($null -eq $qemuImg) {
                    Write-Warning "vm-setup: qemu-img not found; cannot grow data disk for '$($vm.id)'"
                } else {
                    & $qemuImg resize $diskPath $diskBytes
                    if ($LASTEXITCODE -ne 0) {
                        Write-Warning "vm-setup: qemu-img resize failed for '$($vm.id)': $diskPath"
                    }
                }
            } else {
                Write-Information "vm-setup: [dry-run] qemu-img resize '$diskPath' '$diskBytes'"
            }
        }
    }

    if ($Gc) {
        Write-Information 'vm-setup: GC — scanning for non-provisioned VM artifacts...'
        if ($GcDisabled) {
            # WHY: -GcDisabled opts into clearing disabled entries, so only
            # enabled-and-host-matched names are expected.
            $expectedNames = @(
                foreach ($vm in $vmDef.VMs) {
                    if ((Test-VMEnabled $vm) -and (Test-VMHostMatch $vm)) {
                        $vm.id
                    }
                }
            )
        }
        else {
            # WHY: default GC preserves disabled entries; only names absent
            # from VMs.json entirely are cleared.
            $expectedNames = @($vmDef.VMs | ForEach-Object { $_.id })
        }
        Invoke-GcOrphanDisk -ExpectedNames $expectedNames
        Invoke-GcOrphanMarker -ExpectedNames $expectedNames
        Invoke-GcOrphanDescriptor -ExpectedNames $expectedNames
        Write-Information 'vm-setup: GC — done'
    }

    Write-Information 'vm-setup: Windows VM setup complete'
    Write-Information "vm-setup: Disk images at: $vmDir"
    Write-Information "vm-setup: VM directory guide at: $vmReadmePath"
    Write-Information "vm-setup: Run the generated scripts/start-<name>.ps1 (or scripts/start-<name>.sh) scripts to launch VMs"
}

function Invoke-VMSync {
    <#
    .SYNOPSIS
      Refresh VM config (descriptors and start/stop scripts) without building images or disks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [switch]$DryRun
    )

    Invoke-VMSetup -RepoRoot $RepoRoot -DryRun:$DryRun -SyncOnly
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

        [string]$ImageLabel = 'image',

        [Parameter(Mandatory)]
        [long]$MinBytes
    )

    if (-not (Test-Path $ImagePath)) {
        Write-Warning "vm-setup: $ImageLabel not found: $ImagePath"
        return $false
    }

    # check-suppress:suppression_doc: probe -- image file may be unreadable; $null check handles absence.
    $item = Get-Item $ImagePath -ErrorAction SilentlyContinue
    if (-not $item -or $item.Length -le 0) {
        Write-Warning "vm-setup: $ImageLabel is empty or unreadable: $ImagePath"
        return $false
    }

    # check-suppress:suppression_doc: probe whether qemu-img is on PATH; Get-Command throws when absent.
    $qemuImg = Get-Command qemu-img -ErrorAction SilentlyContinue
    if (-not $qemuImg) {
        return $true
    }

    $infoJson = & $qemuImg.Source info --output=json $ImagePath 2>$null  # check-suppress:suppression_doc: probe -- image file may not exist or be corrupt; $LASTEXITCODE checked below
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

    if ([long]$info.'virtual-size' -lt $MinBytes) {
        Write-Warning "vm-setup: $ImageLabel virtual size is too small ($($info.'virtual-size') bytes): $ImagePath"
        return $false
    }

    return $true
}

# Invoke-BuildNixosImage — Builds the NixOS guest image using Packer.
#
# On macOS/NixOS, scripts/vm.sh uses nixos-generators directly (faster,
# no Packer needed).  On Windows, Packer with the QEMU builder downloads the
# NixOS minimal ISO and runs a shell provisioner to install NixOS
# (src\vms\NixOS\packer.pkr.hcl).
function Invoke-BuildNixosImage {
    [CmdletBinding()]
    param(
        [string]$VmName,
        [string]$Accelerator,
        [string]$DiskBytes,
        [string]$MinSize,
        [string]$VmsDir,
        [string]$SrcDir,
        [string]$GuestAccountName,
        [string]$GuestSecret,
        [string]$GuestSecretHash,
        [switch]$DryRun
    )

    $vmType = 'NixOS'
    $outPath = Get-VMSrcPath -SrcDir $SrcDir -Type $vmType -Leaf $VM_SYSTEM_IMAGE
    $credentialMarkerPath = Get-VMGuestSecretMarkerPath -BasePath $outPath
    if (Test-Path $outPath) {
        if (Test-Qcow2Image -ImagePath $outPath -ImageLabel 'existing NixOS image' -MinBytes $MinSize) {
            if (Test-VMGuestSecretMarker -ExpectedHash $GuestSecretHash -MarkerPath $credentialMarkerPath) {
                Write-Information "vm-setup: NixOS image already built for '$VmName' with the current guest credentials (username=$GuestAccountName): $outPath"
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

    # check-suppress:suppression_doc: probe whether packer is installed; Get-Command throws when absent.
    if (-not (Get-Command packer -ErrorAction SilentlyContinue)) {
        Write-Warning 'vm-setup: packer not found; install via WinGet (HashiCorp.Packer)'
        return
    }

    $packerDir = Join-Path $VmsDir 'NixOS'
    $tmpOutput = Get-VMSrcPath -SrcDir $SrcDir -Type $vmType -Leaf $VM_PACKER_BUILD_DIR

    Write-Information "vm-setup: building NixOS image for '$VmName' (accelerator=$Accelerator)..."

    if ($DryRun) {
        Write-Information "vm-setup: [dry-run] Remove stale temporary output directory if present: $tmpOutput"
        Write-Information "vm-setup: [dry-run] cd $packerDir; packer init .; packer build -var accelerator=$Accelerator -var disk_size=${DiskBytes} -var guest_username=$GuestAccountName -var guest_password=<redacted> -var output_directory=$tmpOutput ."
        return
    }

    # check-suppress:suppression_doc: Packer qemu builder requires output_directory to not already exist.
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
            -var "disk_size=${DiskBytes}" `
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

    if (-not (Test-Qcow2Image -ImagePath $outPath -ImageLabel 'newly built NixOS image' -MinBytes $MinSize)) {
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
        # Directory where the downloaded ISO will be placed (src/Windows/).
        [string]$TypeSrcDir,
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

    $cachedIso = Join-Path $TypeSrcDir $VM_WINDOWS_INSTALLER_ISO

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
        # check-suppress:suppression_doc: cleanup-after-failure in finally block; temp-dir removal is best-effort.
        Remove-Item $tmpDir -Recurse -Force -ErrorAction Ignore
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
        [string]$DiskBytes,
        [string]$WindowsIso,
        # Optional URL to auto-download the Windows installer ISO when -WindowsIso
        # is not provided.  Set via the Windows.isoUrl field in VMs.json.
        [string]$WindowsIsoUrl = '',
        [ValidateSet('auto', 'url', 'fido')]
        [string]$WindowsIsoSource = 'Auto',
        [int]$WindowsIsoRetries = 0,
        [string]$Accelerator,
        [string]$VmsDir,
        [string]$SrcDir,
        [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))))),
        [string]$WindowsEdition = 'Pro',
        [string]$GuestAccountName,
        [string]$GuestSecret,
        [string]$GuestSecretHash,
        [string]$MinSize,
        [string]$GuestHostname,
        [string]$HostFwds,
        [switch]$Headful,
        [switch]$DryRun
    )

    $vmType = 'Windows'
    $windowsTypeSrcDir = Get-VMTypeSrcDir -SrcDir $SrcDir -Type $vmType
    $outPath = Get-VMSrcPath -SrcDir $SrcDir -Type $vmType -Leaf $VM_SYSTEM_IMAGE
    $credentialMarkerPath = Get-VMGuestSecretMarkerPath -BasePath $outPath
    if (Test-Path $outPath) {
        if (Test-Qcow2Image -ImagePath $outPath -ImageLabel 'existing Windows image' -MinBytes $MinSize) {
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

    Write-Information "vm-setup: Windows ISO fallback order: cached installer -> Windows.isoUrl -> downloader ($WindowsIsoSource mode)"

    $cachedIso = Get-VMSrcPath -SrcDir $SrcDir -Type $vmType -Leaf $VM_WINDOWS_INSTALLER_ISO
    if (-not $WindowsIso -and (Test-Path $cachedIso)) {
        Write-Information "vm-setup: using cached Windows installer: $cachedIso"
        $WindowsIso = $cachedIso
    }

    # Resolve the installer ISO: use -WindowsIso if provided, otherwise try the
    # VMs.json Windows.isoUrl field as a download source.
    if (-not $WindowsIso -and $WindowsIsoSource -ne 'Fido' -and $WindowsIsoUrl) {
        Write-Information "vm-setup: downloading Windows installer from Windows.isoUrl..."
        if (-not $DryRun) {
            # Use curl.exe (available on Windows 10 1803+) for large ISO downloads;
            # Invoke-WebRequest buffers the full file in memory before writing to disk.
            # Source: https://curl.se/docs/manpage.html
            # check-suppress:suppression_doc: probe whether curl.exe is available; Get-Command throws when absent.
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
                Write-Warning "vm-setup: Windows.isoUrl download attempt $attempt/$maxAttempts failed; retrying in $sleepSeconds seconds"
                Start-Sleep -Seconds $sleepSeconds
                $attempt++
            }

            if (-not $downloadOk) {
                Write-Warning "vm-setup: Windows.isoUrl download failed; removing partial file $cachedIso"
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
            -TypeSrcDir $windowsTypeSrcDir `
            -Edition $WindowsEdition `
            -Retries $WindowsIsoRetries `
            -DryRun:$DryRun
    }
    # If ISO is still empty after all resolution attempts, fail with instructions.
    if (-not $WindowsIso) {
        if ($WindowsIsoSource -eq 'Url') {
            Write-Information 'vm-setup: windowsIsoSource=Url selected and no cached URL-based installer was resolved'
        }
        Write-Information 'vm-setup: alternatively set "Windows": { "isoUrl": "<url>" } on the VMs.json Windows entry'
        Write-Information 'vm-setup: download from: https://www.microsoft.com/software-download/windows11'
        return
    }

    if (-not (Test-Path $WindowsIso)) {
        Write-Warning "vm-setup: Windows ISO not found: $WindowsIso"
        return
    }

    # check-suppress:suppression_doc: probe whether packer is installed; Get-Command throws when absent.
    if (-not (Get-Command packer -ErrorAction SilentlyContinue)) {
        Write-Warning 'vm-setup: packer not found; install via WinGet (HashiCorp.Packer)'
        return
    }

    $packerDir = Join-Path $VmsDir 'Windows'
    $tmpOutput = Get-VMSrcPath -SrcDir $SrcDir -Type $vmType -Leaf $VM_PACKER_BUILD_DIR

    # check-suppress:suppression_doc: This repository currently standardizes Windows guest runtime on BIOS
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

    # check-suppress:suppression_doc: Software emulation (tcg) runs at 2-5% native speed, so Windows PE
    # load + installation + OOBE can take 10-30 real hours.  Use much longer
    # SSH timeouts for tcg compared to hardware-accelerated (whpx) builds.
    # These match the shell script vm.sh build strategy matrix.
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

    # check-suppress:suppression_doc: Packer HCL bool vars are easiest to pass as explicit true/false
    # strings from wrapper scripts for cross-shell consistency.
    $packerHeadless = if ($Headful) { 'false' } else { 'true' }
    $packerDisplayBackend = ''
    if ($Headful) {
        # check-suppress:suppression_doc: Packer defaults to gtk for headful builds, but not every QEMU
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

    Write-Information "vm-setup: building Windows 11 image (disk=${DiskBytes} bytes, accelerator=$Accelerator)..."
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
                    Write-Information "vm-setup: [dry-run] cd $packerDir; packer build -var windows_iso=$WindowsIso -var guest_username=$GuestAccountName -var guest_password=<redacted> -var hostfwd=$HostFwds -var guest_hostname=$GuestHostname -var autounattend_path=$(Join-Path $VmsDir 'Windows\\Autounattend.xml') -var accelerator=$Accelerator -var firmware_mode=$($attempt.Firmware) -var boot_strategy=$($attempt.Boot) -var ssh_timeout=$($attempt.Timeout) -var headless=$packerHeadless -var display_backend=$packerDisplayBackend -var efi_firmware_code=$efiCode -var efi_firmware_vars=$efiVars -var disk_size=${DiskBytes} -var output_directory=$tmpOutput ."
                } else {
                    Write-Information "vm-setup: [dry-run] cd $packerDir; packer build -var windows_iso=$WindowsIso -var guest_username=$GuestAccountName -var guest_password=<redacted> -var hostfwd=$HostFwds -var guest_hostname=$GuestHostname -var autounattend_path=$(Join-Path $VmsDir 'Windows\\Autounattend.xml') -var accelerator=$Accelerator -var firmware_mode=$($attempt.Firmware) -var boot_strategy=$($attempt.Boot) -var ssh_timeout=$($attempt.Timeout) -var headless=$packerHeadless -var efi_firmware_code=$efiCode -var efi_firmware_vars=$efiVars -var disk_size=${DiskBytes} -var output_directory=$tmpOutput ."
                }
            } else {
                if ($Headful) {
                    Write-Information "vm-setup: [dry-run] cd $packerDir; packer build -var windows_iso=$WindowsIso -var guest_username=$GuestAccountName -var guest_password=<redacted> -var hostfwd=$HostFwds -var guest_hostname=$GuestHostname -var autounattend_path=$(Join-Path $VmsDir 'Windows\\Autounattend.xml') -var accelerator=$Accelerator -var firmware_mode=$($attempt.Firmware) -var boot_strategy=$($attempt.Boot) -var ssh_timeout=$($attempt.Timeout) -var headless=$packerHeadless -var display_backend=$packerDisplayBackend -var disk_size=${DiskBytes} -var output_directory=$tmpOutput ."
                } else {
                    Write-Information "vm-setup: [dry-run] cd $packerDir; packer build -var windows_iso=$WindowsIso -var guest_username=$GuestAccountName -var guest_password=<redacted> -var hostfwd=$HostFwds -var guest_hostname=$GuestHostname -var autounattend_path=$(Join-Path $VmsDir 'Windows\\Autounattend.xml') -var accelerator=$Accelerator -var firmware_mode=$($attempt.Firmware) -var boot_strategy=$($attempt.Boot) -var ssh_timeout=$($attempt.Timeout) -var headless=$packerHeadless -var disk_size=${DiskBytes} -var output_directory=$tmpOutput ."
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

            # check-suppress:suppression_doc: Packer qemu builder requires output_directory to not already exist.
            # Use a fresh temp tree per attempt so a failed try cannot poison the
            # next firmware/boot-strategy combination.
            $attemptTempDir = Join-Path $windowsTypeSrcDir ('.{0}.{1}.{2}.{3}' -f $VmName, $attempt.Firmware, $attempt.Boot, ([guid]::NewGuid().ToString('N')))
            New-Item -ItemType Directory -Path $attemptTempDir -Force > $null
            $tmpOutput = Join-Path $attemptTempDir 'output'
            $packerLog = Join-Path $attemptTempDir 'packer.log'
            $autounattendTemplate = Join-Path $VmsDir 'Windows\Autounattend.xml'
            $autounattendRendered = Join-Path $attemptTempDir 'Autounattend.xml'
            $autounattendContent = Get-Content -Path $autounattendTemplate -Raw
            $autounattendContent = $autounattendContent.Replace('__NUCLEUS_GUEST_USERNAME__', $GuestAccountName)
            $autounattendContent = $autounattendContent.Replace('__NUCLEUS_GUEST_PASSWORD__', $GuestSecret)
            $autounattendContent = $autounattendContent.Replace('__GUEST_HOSTNAME__', $GuestHostname)
            Set-Content -Path $autounattendRendered -Value $autounattendContent -Encoding UTF8
            Write-Information "vm-setup: writing Packer debug log for this attempt: $packerLog"

            $packerArgs = @(
                '-var', "windows_iso=$WindowsIso",
                '-var', "guest_username=$GuestAccountName",
                '-var', "guest_password=$GuestSecret",
                '-var', "hostfwd=$HostFwds",
                '-var', "guest_hostname=$GuestHostname",
                '-var', "autounattend_path=$autounattendRendered",
                '-var', "accelerator=$Accelerator",
                '-var', "firmware_mode=$($attempt.Firmware)",
                '-var', "boot_strategy=$($attempt.Boot)",
                '-var', "ssh_timeout=$($attempt.Timeout)",
                '-var', "headless=$packerHeadless",
                '-var', "disk_size=${DiskBytes}",
                '-var', "output_directory=$tmpOutput",
                '.'
            )
            if ($Headful) {
                $packerArgs = @(
                    '-var', "windows_iso=$WindowsIso",
                    '-var', "guest_username=$GuestAccountName",
                    '-var', "guest_password=$GuestSecret",
                    '-var', "hostfwd=$HostFwds",
                    '-var', "guest_hostname=$GuestHostname",
                    '-var', "autounattend_path=$autounattendRendered",
                    '-var', "accelerator=$Accelerator",
                    '-var', "firmware_mode=$($attempt.Firmware)",
                    '-var', "boot_strategy=$($attempt.Boot)",
                    '-var', "ssh_timeout=$($attempt.Timeout)",
                    '-var', "headless=$packerHeadless",
                    '-var', "display_backend=$packerDisplayBackend",
                    '-var', "disk_size=${DiskBytes}",
                    '-var', "output_directory=$tmpOutput",
                    '.'
                )
            }
            if ($attempt.Firmware -eq 'efi') {
                $packerArgs = @(
                    '-var', "windows_iso=$WindowsIso",
                    '-var', "guest_username=$GuestAccountName",
                    '-var', "guest_password=$GuestSecret",
                    '-var', "hostfwd=$HostFwds",
                    '-var', "guest_hostname=$GuestHostname",
                    '-var', "autounattend_path=$autounattendRendered",
                    '-var', "accelerator=$Accelerator",
                    '-var', "firmware_mode=$($attempt.Firmware)",
                    '-var', "boot_strategy=$($attempt.Boot)",
                    '-var', "ssh_timeout=$($attempt.Timeout)",
                    '-var', "headless=$packerHeadless",
                    '-var', "efi_firmware_code=$efiCode",
                    '-var', "efi_firmware_vars=$efiVars",
                    '-var', "disk_size=${DiskBytes}",
                    '-var', "output_directory=$tmpOutput",
                    '.'
                )
                if ($Headful) {
                    $packerArgs = @(
                        '-var', "windows_iso=$WindowsIso",
                        '-var', "guest_username=$GuestAccountName",
                        '-var', "guest_password=$GuestSecret",
                        '-var', "hostfwd=$HostFwds",
                        '-var', "guest_hostname=$GuestHostname",
                        '-var', "autounattend_path=$autounattendRendered",
                        '-var', "accelerator=$Accelerator",
                        '-var', "firmware_mode=$($attempt.Firmware)",
                        '-var', "boot_strategy=$($attempt.Boot)",
                        '-var', "ssh_timeout=$($attempt.Timeout)",
                        '-var', "headless=$packerHeadless",
                        '-var', "display_backend=$packerDisplayBackend",
                        '-var', "efi_firmware_code=$efiCode",
                        '-var', "efi_firmware_vars=$efiVars",
                        '-var', "disk_size=${DiskBytes}",
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
                # check-suppress:suppression_doc: cleanup-after-failure; temp dir may not exist if cancelled early.
                Remove-Item $attemptTempDir -Recurse -Force -ErrorAction Ignore
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

    if (-not (Test-Qcow2Image -ImagePath $outPath -ImageLabel 'newly built Windows image' -MinBytes $MinSize)) {
        Write-Warning "vm-setup: Windows image validation failed after build; removing $outPath"
        Remove-Item $outPath -Force
        return
    }

    Write-Information "vm-setup: Windows 11 image ready: $outPath"
}
