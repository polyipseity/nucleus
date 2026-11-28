<#
.SYNOPSIS
  Clears and repairs enable gates for registry-managed Windows services.

.DESCRIPTION
  The enable pass runs before DSC and sets the registry's enable state without
  starting anything. The repair pass runs after DSC and the service Sync-* steps
  and acts only on targets the enable pass cleared that are not loaded yet. Both
  passes resolve instances through the shared Windows service resolver.

.NOTES
  Requirements: Windows Service and ScheduledTasks cmdlets.
  Environment variables: none.
#>

# The row shapes and instance enumeration come from the resolver svc.ps1 uses.
. (Join-Path $PSScriptRoot 'Get-NucleusServiceInstance.ps1')
# Folder-qualified task ids are split by the scheduler adapter, not by Split-Path.
. (Join-Path $PSScriptRoot 'Supervisor-Schtask.ps1')
# SCM repair reuses the create-or-update-and-start helper directly.
. (Join-Path $PSScriptRoot 'Set-NucleusService.ps1')

function Get-NucleusHostServiceEntries {
  <#
  .SYNOPSIS
    Filters a raw services registry down to one host's managed entries.

  .DESCRIPTION
    Entries without a host row and entries whose host type is omitted are
    dropped. The returned shape matches the registry svc.ps1 builds, so both
    callers read the same fields.

  .PARAMETER RegistryRaw
    Hashtable read from services.json with ConvertFrom-Json -AsHashtable.

  .PARAMETER HostKey
    Canonical host name, for example Windows.

  .OUTPUTS
    System.Collections.Hashtable keyed by registry service name.
  #>
  # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- pure registry filter; no system state changes
  [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
  # check-suppress:SuppressMessageAttribute: PSUseSingularNouns -- the registry value holds several host entries
  [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)]
    [hashtable]$RegistryRaw,

    [Parameter(Mandatory)]
    [string]$HostKey
  )

  $entries = @{}
  foreach ($key in $RegistryRaw.Keys) {
    $entry = $RegistryRaw[$key]
    if ($entry -isnot [hashtable]) { continue }
    if (-not $entry.ContainsKey('hosts')) { continue }
    $hosts = $entry.hosts
    if ($hosts -isnot [hashtable] -or -not $hosts.ContainsKey($HostKey)) { continue }

    $hostEntry = $hosts[$HostKey]
    if ($hostEntry -isnot [hashtable]) { continue }
    if ($hostEntry.ContainsKey('type') -and $hostEntry.type -eq 'omitted') { continue }

    $entries[$key] = @{
      displayName = if ($entry.ContainsKey('displayName')) { $entry.displayName } else { $key }
      description = if ($entry.ContainsKey('description')) { $entry.description } else { $null }
      network     = if ($entry.ContainsKey('network')) { $entry.network } else { $null }
      hostEntry   = $hostEntry
    }
  }
  return $entries
}

function Resolve-NucleusServiceRows {
  <#
  .SYNOPSIS
    Expands filtered registry entries into live service rows.

  .DESCRIPTION
    A prefix-match entry contributes one row per live supervisor instance.
    Configured-only ids are intentionally absent: no enable or repair verb may
    touch an instance that is not loaded.

  .PARAMETER Registry
    Filtered registry from Get-NucleusHostServiceEntries.

  .OUTPUTS
    Hashtable[] with registryKey, displayName, hostEntry, instanceId and class.
  #>
  # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- pure row builder; no system state changes
  [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
  # check-suppress:SuppressMessageAttribute: PSUseSingularNouns -- one entry can expand into several rows
  [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
  [CmdletBinding()]
  [OutputType([hashtable[]])]
  param(
    [Parameter(Mandatory)]
    [hashtable]$Registry
  )

  $rows = @()
  foreach ($key in @($Registry.Keys | Sort-Object)) {
    $entry = $Registry[$key]
    $hostEntry = $entry.hostEntry

    if ($hostEntry.ContainsKey('prefixMatch') -and $hostEntry.prefixMatch) {
      foreach ($id in @(Get-NucleusPrefixInstanceList -HostEntry $hostEntry)) {
        $instanceEntry = New-NucleusInstanceHostEntry -HostEntry $hostEntry -InstanceId $id
        $suffix = Get-NucleusInstanceSuffix -HostEntry $hostEntry -InstanceId $id
        $rows += @{
          registryKey = $key
          displayName = "$($entry.displayName) ($suffix)"
          hostEntry   = $instanceEntry
          instanceId  = $id
          class       = 'live'
        }
      }
      continue
    }

    $rows += @{
      registryKey = $key
      displayName = $entry.displayName
      hostEntry   = $hostEntry
      instanceId  = $key
      class       = 'live'
    }
  }
  return [hashtable[]]@($rows)
}

function Test-NucleusNotLoadedError {
  <#
  .SYNOPSIS
    Reports whether a supervisor probe error means the target is absent.

  .DESCRIPTION
    Only a clear not-found error means not loaded. Access denied or a transient
    probe failure must reach the caller as an error instead.

  .PARAMETER ErrorRecord
    Error record from the probe.

  .OUTPUTS
    System.Boolean
  #>
  # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- pure error classifier; no system state changes
  [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [System.Management.Automation.ErrorRecord]$ErrorRecord
  )

  if ($ErrorRecord.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::ObjectNotFound) { return $true }
  $message = [string]$ErrorRecord.Exception.Message
  if ($message -match '(?i)cannot find|not found|does not exist|no service found') { return $true }
  return $false
}

function Enable-ManagedServiceSet {
  <#
  .SYNOPSIS
    Clears the enable gate of every live registry target on one host.

  .DESCRIPTION
    Native services get StartupType Automatic and scheduled tasks are enabled.
    User autostart rows have no enable gate and are returned without a change.
    No target is started here. The returned ids are the targets this pass
    cleared, for the repair pass to consider after convergence.

  .PARAMETER RegistryPath
    Path to src/modules/services.json.

  .PARAMETER HostKey
    Canonical host name, for example Windows.

  .OUTPUTS
    System.String[]: cleared instance ids, sorted and unique.

  .EXAMPLE
    $cleared = Enable-ManagedServiceSet -RegistryPath 'C:\repo\src\modules\services.json' -HostKey 'Windows'
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory)]
    [string]$RegistryPath,

    [Parameter(Mandatory)]
    [string]$HostKey
  )

  if (-not (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) {
    throw "Enable-ManagedServiceSet: registry not found at '$RegistryPath'"
  }
  $raw = Get-Content -LiteralPath $RegistryPath -Raw | ConvertFrom-Json -AsHashtable
  $registry = Get-NucleusHostServiceEntries -RegistryRaw $raw -HostKey $HostKey
  $rows = Resolve-NucleusServiceRows -Registry $registry

  $cleared = @()
  foreach ($row in $rows) {
    $hostEntry = $row.hostEntry
    switch ($hostEntry.type) {
      'windows-native' {
        Set-Service -Name $hostEntry.service -StartupType Automatic -ErrorAction Stop
      }
      'windows-schtask' {
        $parts = Split-SupervisorTarget -Target $hostEntry.taskPath
        Enable-ScheduledTask -TaskPath $parts.Path -TaskName $parts.Name -ErrorAction Stop
      }
      'windows-user-autostart' {
        # WHY: the HKCU Run value has no SCM or scheduler enable gate. The user
        # activation step owns this carrier, so there is nothing to clear here.
      }
      default {
        throw "Enable-ManagedServiceSet: unsupported type '$($hostEntry.type)' for $($row.instanceId)"
      }
    }
    $cleared += $row.instanceId
  }
  return [string[]]@($cleared | Sort-Object -Unique)
}

function Test-NucleusScmLoaded {
  <#
  .SYNOPSIS
    Reports whether a native service is registered, enabled and running.

  .DESCRIPTION
    A failed probe throws. A clean not-found reports not loaded so the repair
    pass can bootstrap the service.

  .PARAMETER Name
    SCM service name.

  .OUTPUTS
    System.Boolean
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [string]$Name
  )

  try {
    $service = Get-Service -Name $Name -ErrorAction Stop
  } catch {
    if (Test-NucleusNotLoadedError -ErrorRecord $_) { return $false }
    throw "loaded-state probe for $Name failed: $($_.Exception.Message)"
  }
  if ($null -eq $service) { return $false }
  return ($service.Status -eq 'Running' -and $service.StartType -ne 'Disabled')
}

function Get-NucleusScheduledTask {
  <#
  .SYNOPSIS
    Reads one scheduled task for a loaded-state probe.

  .DESCRIPTION
    Uses the scheduler adapter's probe: an unregistered task is an expected
    result, so errors are silenced and a null result means the task is absent.
    A terminating probe failure still throws.

  .PARAMETER TaskPath
    Task folder from Split-SupervisorTarget.

  .PARAMETER TaskName
    Task name from Split-SupervisorTarget.

  .OUTPUTS
    Scheduled task object, or $null when absent.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$TaskPath,

    [Parameter(Mandatory)]
    [string]$TaskName
  )

  try {
    # check-suppress:suppression_doc: probe -- an unregistered task is expected; the null check below handles absence
    $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
  } catch {
    throw "loaded-state probe for $TaskName failed: $($_.Exception.Message)"
  }
  if ($null -eq $task) { return $null }
  return $task
}

function Get-NucleusScmBinaryPath {
  <#
  .SYNOPSIS
    Reads the registered command line of an SCM service.

  .DESCRIPTION
    Returns $null when SCM has no registration for the name. A failed CIM read
    throws so repair never creates a service with an empty command line.

  .PARAMETER Name
    SCM service name.

  .OUTPUTS
    System.String, or $null when the service is absent.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$Name
  )

  try {
    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction Stop
  } catch {
    throw "could not read the SCM definition of $Name`: $($_.Exception.Message)"
  }
  if ($null -eq $service) { return $null }
  return [string]$service.PathName
}

function Repair-ManagedServiceSet {
  <#
  .SYNOPSIS
    Repairs only the cleared targets that are still not loaded after convergence.

  .DESCRIPTION
    Native services go through Set-NucleusService, which creates or updates the
    registration and starts it. Tasks that re-registration left disabled are
    enabled with Enable-ScheduledTask. Each target is acted on at most once,
    and a failed loaded-state probe throws before any target is touched.

  .PARAMETER RegistryPath
    Path to src/modules/services.json.

  .PARAMETER HostKey
    Canonical host name, for example Windows.

  .PARAMETER Targets
    Instance ids cleared by Enable-ManagedServiceSet.

  .EXAMPLE
    Repair-ManagedServiceSet -RegistryPath 'C:\repo\src\modules\services.json' -HostKey 'Windows' -Targets $cleared
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RegistryPath,

    [Parameter(Mandatory)]
    [string]$HostKey,

    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [string[]]$Targets
  )

  if (-not (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) {
    throw "Repair-ManagedServiceSet: registry not found at '$RegistryPath'"
  }
  $raw = Get-Content -LiteralPath $RegistryPath -Raw | ConvertFrom-Json -AsHashtable
  $registry = Get-NucleusHostServiceEntries -RegistryRaw $raw -HostKey $HostKey
  $rows = Resolve-NucleusServiceRows -Registry $registry
  $rowsById = @{}
  foreach ($row in $rows) { $rowsById[$row.instanceId] = $row }

  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($target in $Targets) {
    if ([string]::IsNullOrWhiteSpace($target)) { continue }
    if (-not $seen.Add($target)) { continue }
    if (-not $rowsById.ContainsKey($target)) {
      throw "Repair-ManagedServiceSet: no live registry target for '$target'"
    }

    $row = $rowsById[$target]
    $hostEntry = $row.hostEntry
    switch ($hostEntry.type) {
      'windows-native' {
        if (Test-NucleusScmLoaded -Name $hostEntry.service) { continue }
        $binaryPath = $null
        if ($hostEntry.ContainsKey('binaryPath')) { $binaryPath = [string]$hostEntry.binaryPath }
        if ([string]::IsNullOrWhiteSpace($binaryPath)) { $binaryPath = Get-NucleusScmBinaryPath -Name $hostEntry.service }
        if ([string]::IsNullOrWhiteSpace($binaryPath)) {
          throw "Repair-ManagedServiceSet: no SCM definition for '$target'; cannot bootstrap without a binary path"
        }
        Set-NucleusService -Name $hostEntry.service -BinaryPath $binaryPath -DisplayName $row.displayName -StartType Automatic
      }
      'windows-schtask' {
        $parts = Split-SupervisorTarget -Target $hostEntry.taskPath
        $task = Get-NucleusScheduledTask -TaskPath $parts.Path -TaskName $parts.Name
        if ($null -ne $task -and $task.Settings.Enabled) { continue }
        Enable-ScheduledTask -TaskPath $parts.Path -TaskName $parts.Name -ErrorAction Stop
      }
      'windows-user-autostart' {
        # WHY: the HKCU Run value is written before logon, so it has no loaded
        # state for the post-apply repair pass to probe or restart.
      }
      default {
        throw "Repair-ManagedServiceSet: unsupported type '$($hostEntry.type)' for $target"
      }
    }
  }
}
