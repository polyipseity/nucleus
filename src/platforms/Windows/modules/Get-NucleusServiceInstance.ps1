<#
.SYNOPSIS
  Instance resolution for prefix-match services (services.json entries with prefixMatch: true).

.DESCRIPTION
  A prefix-match entry stands in for one runtime service per configured instance, so the
  concrete ids only exist at runtime. This module is the single Windows implementation of
  that mapping and mirrors src/scripts/lib/svc-instances.sh: scripts/svc.ps1 (list, status,
  actions, verify) resolves through it.

  Scheduled-task ids are folder-qualified: a task named NucleusCloudMount-iCloud in the
  \NucleusCloudMount\ folder has the id \NucleusCloudMount\NucleusCloudMount-iCloud, and a
  task registered in the root folder has its bare name as the id. The registry splits that
  id across two fields: taskPath is the folder, service is the task-name prefix.

.NOTES
  Requirements: Get-ScheduledTask for live enumeration.
  Environment variables: none.
#>

function Get-NucleusInstanceId {
  <#
  .SYNOPSIS
    Builds a full instance id from a task folder path and a task name.

  .PARAMETER TaskFolder
    Task folder path as reported by Get-ScheduledTask. May be empty or a lone separator
    for the root folder.

  .PARAMETER TaskName
    Task name.

  .OUTPUTS
    System.String
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$TaskFolder,

    [Parameter(Mandatory)]
    [string]$TaskName
  )

  $folder = $TaskFolder.TrimEnd('\')
  if ([string]::IsNullOrEmpty($folder)) {
    return $TaskName
  }
  return "$folder\$TaskName"
}

function Get-NucleusInstanceIdPrefix {
  <#
  .SYNOPSIS
    Returns the full-id prefix shared by every instance of a prefix-match entry.

  .DESCRIPTION
    A scheduled-task entry declares the folder in taskPath and the task-name prefix in
    service, so the id prefix combines both — '\NucleusCloudMount' plus
    'NucleusCloudMount-' yields '\NucleusCloudMount\NucleusCloudMount-'.

  .PARAMETER HostEntry
    Host entry hashtable from services.json.

  .OUTPUTS
    System.String

  .EXAMPLE
    Get-NucleusInstanceIdPrefix -HostEntry $entry
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [hashtable]$HostEntry
  )

  if (-not $HostEntry.ContainsKey('service') -or [string]::IsNullOrEmpty($HostEntry.service)) {
    throw "Get-NucleusInstanceIdPrefix: host entry has no service prefix (type '$($HostEntry.type)')"
  }

  $folder = if ($HostEntry.ContainsKey('taskPath')) { [string]$HostEntry.taskPath } else { '' }
  return Get-NucleusInstanceId -TaskFolder $folder -TaskName ([string]$HostEntry.service)
}

function Get-NucleusInstanceSuffix {
  <#
  .SYNOPSIS
    Returns the per-instance suffix of a concrete instance id (the mount id).

  .DESCRIPTION
    The suffix names the instance-specific runtime state — log directories, crash-loop
    state — so it must derive from the registry prefix rather than be stored separately.
    The unit-type suffix (.service) is dropped when present.

  .PARAMETER HostEntry
    Host entry hashtable from services.json.

  .PARAMETER InstanceId
    Concrete instance id, as returned by Get-NucleusPrefixInstanceList.

  .OUTPUTS
    System.String

  .EXAMPLE
    Get-NucleusInstanceSuffix -HostEntry $entry -InstanceId '\NucleusCloudMount\NucleusCloudMount-iCloud'
    # returns iCloud
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [hashtable]$HostEntry,

    [Parameter(Mandatory)]
    [string]$InstanceId
  )

  $segment = ($InstanceId -split '[\\/]')[-1]
  if ($HostEntry.ContainsKey('service')) {
    $service = [string]$HostEntry.service
    if ($service -and $segment.StartsWith($service, [System.StringComparison]::Ordinal)) {
      $segment = $segment.Substring($service.Length)
    }
  }
  if ($segment.EndsWith('.service', [System.StringComparison]::Ordinal)) {
    $segment = $segment.Substring(0, $segment.Length - '.service'.Length)
  }
  return $segment
}

function New-NucleusInstanceHostEntry {
  <#
  .SYNOPSIS
    Builds the concrete host entry for a single instance.

  .DESCRIPTION
    The returned entry carries the instance id as its runtime identity (taskPath for
    scheduled tasks, service otherwise) and drops prefixMatch, so status and action helpers
    treat it as an ordinary service instead of another expansion.

  .PARAMETER HostEntry
    Host entry hashtable of the prefix-match entry.

  .PARAMETER InstanceId
    Concrete instance id.

  .OUTPUTS
    System.Collections.Hashtable

  .EXAMPLE
    New-NucleusInstanceHostEntry -HostEntry $entry -InstanceId '\NucleusCloudMount\NucleusCloudMount-iCloud'
  #>
  # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- pure builder of an in-memory entry; no system state changes
  [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)]
    [hashtable]$HostEntry,

    [Parameter(Mandatory)]
    [string]$InstanceId
  )

  $entry = @{}
  foreach ($key in $HostEntry.Keys) {
    if ($key -eq 'prefixMatch') { continue }
    $entry[$key] = $HostEntry[$key]
  }

  if ($HostEntry.ContainsKey('type') -and $HostEntry.type -eq 'schtask') {
    $entry.taskPath = $InstanceId
  } else {
    $entry.service = $InstanceId
  }
  return $entry
}

function Get-NucleusPrefixInstanceList {
  <#
  .SYNOPSIS
    Lists the live instances of a prefix-match entry.

  .DESCRIPTION
    Enumerates scheduled tasks and keeps those whose full id starts with the entry's id
    prefix. The match is an anchored literal string comparison, never a wildcard, so a
    missing or empty prefix cannot match unrelated tasks.

  .PARAMETER HostEntry
    Host entry hashtable of the prefix-match entry.

  .OUTPUTS
    System.String[] — concrete instance ids, sorted; empty when none exist.
    Callers must wrap the call in @() to keep a single id an array.

  .EXAMPLE
    Get-NucleusPrefixInstanceList -HostEntry $entry
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory)]
    [hashtable]$HostEntry
  )

  if (-not $HostEntry.ContainsKey('type')) {
    throw 'Get-NucleusPrefixInstanceList: host entry has no type'
  }
  if ($HostEntry.type -ne 'schtask') {
    throw "Get-NucleusPrefixInstanceList: unsupported type '$($HostEntry.type)' for a prefix-match entry"
  }

  $prefix = Get-NucleusInstanceIdPrefix -HostEntry $HostEntry
  $instances = foreach ($task in Get-ScheduledTask) {
    $instanceId = Get-NucleusInstanceId -TaskFolder $task.TaskPath -TaskName $task.TaskName
    if ($instanceId.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
      $instanceId
    }
  }
  # WHY: emit the ids normally and let callers wrap the call in @(). Preserving
  # array shape here (a leading comma) would make @(Get-...) a one-element array
  # holding the real array, which silently breaks every .Count check.
  return [string[]]@($instances | Sort-Object -Unique)
}

function Get-NucleusConfiguredInstanceList {
  <#
  .SYNOPSIS
    Lists the instance ids the user registry declares for a prefix-match entry.

  .DESCRIPTION
    A mount declared in src/users/<user>/cloud-drives.json is expected to run even
    while its scheduled task does not exist, so the expected ids are derived from the
    registry entry (task folder + task-name prefix + mount id) instead of being stored
    a second time. Discovery only reads: it never registers a task.

  .PARAMETER HostEntry
    Host entry hashtable of the prefix-match entry.

  .PARAMETER Username
    Single user record to read. When omitted, every user is read — the watchdog runs
    as SYSTEM and reconciles all users.

  .PARAMETER RepoRoot
    Absolute repository root. Defaults to $env:NUCLEUS_REPO_ROOT.

  .OUTPUTS
    System.String[] — expected instance ids, sorted; empty when none are declared.
    Callers must wrap the call in @() to keep a single id an array.

  .EXAMPLE
    Get-NucleusConfiguredInstanceList -HostEntry $entry -Username 'admin'
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory)]
    [hashtable]$HostEntry,

    [string]$Username,

    [string]$RepoRoot
  )

  if ($HostEntry.type -ne 'schtask') {
    throw "Get-NucleusConfiguredInstanceList: unsupported type '$($HostEntry.type)' for a prefix-match entry"
  }

  $effectiveRepoRoot = $RepoRoot
  if ([string]::IsNullOrWhiteSpace($effectiveRepoRoot)) { $effectiveRepoRoot = $env:NUCLEUS_REPO_ROOT }
  if ([string]::IsNullOrWhiteSpace($effectiveRepoRoot)) {
    throw 'Get-NucleusConfiguredInstanceList: no repository root (pass -RepoRoot or set NUCLEUS_REPO_ROOT)'
  }

  $loader = Join-Path -Path $PSScriptRoot -ChildPath 'Load-UserRegistry.ps1'
  if (-not (Test-Path -Path $loader -PathType Leaf)) {
    throw "Get-NucleusConfiguredInstanceList: user registry loader not found at '$loader'"
  }

  $registry = & $loader -RepoRoot $effectiveRepoRoot
  $records = @($registry.users)
  if (-not [string]::IsNullOrWhiteSpace($Username)) {
    $records = @($records | Where-Object { $_.name -eq $Username })
  }

  $ids = @()
  foreach ($record in $records) {
    foreach ($mount in @($record.cloudDrives.mounts)) {
      if ($null -eq $mount) { continue }
      # WHY: enable is optional in the mount schema and defaults to true, matching
      # the Nix-side submodule default that decides which mounts are instantiated.
      $enabled = if ($mount.ContainsKey('enable')) { [bool]$mount.enable } else { $true }
      if (-not $enabled) { continue }
      if (-not $mount.ContainsKey('remoteName')) { continue }
      if ([string]::IsNullOrWhiteSpace([string]$mount.remoteName)) { continue }
      $ids += Get-NucleusInstanceId -TaskFolder ([string]$HostEntry.taskPath) -TaskName "$([string]$HostEntry.service)$([string]$mount.id)"
    }
  }

  return [string[]]@($ids | Sort-Object -Unique)
}
