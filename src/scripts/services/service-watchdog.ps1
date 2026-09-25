<#
.SYNOPSIS
  Persistent-loop service watchdog for Windows.

.DESCRIPTION
  Detects and breaks restart loops, and revives stopped nucleus-managed
  services, using exactly one rule table shared with the POSIX watchdog
  (src/scripts/services/service-watchdog.sh).  The rules are applied in this
  order, and the order is load-bearing.  The numbers are names, not positions:
  evaluation follows the list below, so Rule 5 runs before Rule 4 and Rule 4b
  sits between Rule 2 and the probe.

    1. user-disabled (or not registered) -> report once, do nothing
    2. blocked record                    -> report once, do nothing
    4b. record already says not-loaded   -> report once, no action until apply
    3. live + looping                    -> block + stop
    5. live + broken (EX_CONFIG)         -> repair
    4. not live + not blocked            -> start (the only revival path)

  A block is never auto-cleared.  Only a reboot (the health record's boot id no
  longer matches) or an explicit re-arm (nucleus-apply -> Health-ClearAll)
  clears one, which is why Rule 2 must precede Rule 4.

  Health state lives in one unified record per instance (ServiceHealth.ps1),
  the same record shape the POSIX watchdog and the mount runner use.  Start,
  stop, and repair go through exactly one Supervisor-* adapter chosen by the
  service kind (SCM for native services, Task Scheduler for scheduled tasks),
  so no rule body branches on the kind.

  Reads src/modules/services.json, filters to Windows, and expands prefix-match
  entries per instance.  An instance the user registry declares but Windows does
  not run is reported once per transition through the health record's reported
  state instead of being started.
  Runs indefinitely, sleeping cloud-drive.lifecycle.watchdogTickSeconds between iterations (persistent daemon
  pattern — launched by scheduled task AtStartup).
  Use -Oneshot to run a single iteration (for manual or CI use).

.PARAMETER Oneshot
  Run one iteration and exit instead of sleeping forever.
#>

param(
  [switch]$Oneshot
)

$ErrorActionPreference = "Stop"

$modulePath = Join-Path $PSScriptRoot '..\..\..\src\platforms\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force -DisableNameChecking

# ── Resolve repo root ──────────────────────────────────────────────────────
$RepoRoot = if ($env:NUCLEUS_REPO_ROOT) {
  $env:NUCLEUS_REPO_ROOT
} else {
  Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

$ModulesDir = Join-Path $RepoRoot 'src\platforms\Windows\modules'

. (Join-Path $ModulesDir 'Get-NucleusServiceInstance.ps1')
. (Join-Path $ModulesDir 'ServiceHealth.ps1')

$ServicesJson = Join-Path $RepoRoot "src\modules\services.json"
if (-not (Test-Path $ServicesJson)) {
  Write-NucleusInfo "services registry not found at $ServicesJson"
  exit 1
}

$RegistryRaw = Get-Content $ServicesJson -Raw | ConvertFrom-Json -AsHashtable
$NucleusHost = 'Windows'

# ── Filter to watchdog-managed services ────────────────────────────────────
# Exclude: registry-level blocks, omitted, socket-activated.  Prefix-match
# entries are kept and expanded per instance during the iteration.
$Services = @()
foreach ($key in $RegistryRaw.Keys) {
  # $schema and $logging are registry-level blocks with no hosts, so they are not
  # service entries.  The POSIX watchdog selects keys the same way, with
  # jq 'keys[] | select(startswith("$") | not)'.
  if ($key.StartsWith('$')) { continue }

  $entry = $RegistryRaw[$key]
  if ($entry -isnot [hashtable]) { continue }
  if (-not $entry.hosts.ContainsKey($NucleusHost)) { continue }

  $hostEntry = $entry.hosts[$NucleusHost]
  if ($hostEntry.type -eq "omitted") { continue }
  if ($hostEntry.socketActivated) { continue }

  $Services += @{
    key         = $key
    displayName = $entry.displayName
    type        = $hostEntry.type
    service     = $hostEntry.service
    taskPath    = $hostEntry.taskPath
    prefixMatch = [bool]$hostEntry.prefixMatch
    hostEntry   = $hostEntry
  }
}

# ── Supervisor adapter selection ───────────────────────────────────────────
# Both adapters export the same eight Supervisor-* functions, so exactly one may
# be loaded at a time.  The kind is remembered so repeated iterations do not
# re-dot-source the adapter on every service.
$script:LoadedSupervisorKind = $null

function Import-SupervisorAdapter {
  <#
  .SYNOPSIS
    Loads the Supervisor-* adapter for a service kind, replacing any other.
  .DESCRIPTION
    SCM and Task Scheduler both expose Supervisor-Enabled/Live/Counter/LastExit/
    Start/Stop/Repair/Kind with an identical -Target signature, so the watchdog
    loads precisely one and calls the interface without branching on the kind.
  .PARAMETER Kind
    Adapter kind: 'scm' for native services, 'schtask' for scheduled tasks.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Kind)

  if ($script:LoadedSupervisorKind -eq $Kind) { return }

  $adapter = switch ($Kind) {
    'scm' { 'Supervisor-Scm.ps1' }
    'schtask' { 'Supervisor-Schtask.ps1' }
    default { throw "Import-SupervisorAdapter: no supervisor adapter for kind '$Kind'" }
  }

  # WHY: dot-sourcing the adapter inside this function would define its functions
  # in the function's own scope and discard them on return, so every definition is
  # installed into the script scope instead.  Installing a different adapter
  # replaces the previous one outright, including its private helpers, which is
  # what keeps exactly one adapter loaded at a time.
  $adapterPath = Join-Path $ModulesDir $adapter
  $tokens = $null
  $parseErrors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($adapterPath, [ref]$tokens, [ref]$parseErrors)
  if ($parseErrors.Count -gt 0) {
    throw "Import-SupervisorAdapter: ${adapter} failed to parse: $($parseErrors[0].Message)"
  }
  foreach ($definition in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    Set-Item -Path "Function:script:$($definition.Name)" -Value $definition.Body.GetScriptBlock()
  }

  $script:LoadedSupervisorKind = $Kind
}

# ── Adapter kind for a service type ────────────────────────────────────────
function Get-SupervisorKindForType {
  <#
  .SYNOPSIS
    Maps a services.json host type to a supervisor adapter kind.
  .PARAMETER Type
    Windows host entry type from src/modules/services.json.
  .OUTPUTS
    System.String, or $null when the type is not supervisor-driven.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][string]$Type)

  switch ($Type) {
    'windows-native' { 'scm' }
    'windows-schtask' { 'schtask' }
    default { $null }
  }
}

# ── Instance resolution ────────────────────────────────────────────────────
function Get-InstanceTargetList {
  <#
  .SYNOPSIS
    Resolves the instances one registry entry contributes to an iteration.
  .DESCRIPTION
    A plain entry contributes its own instance.  A prefix-match entry (the
    cloud-drive mounts) contributes every instance the user registry declares,
    answered here so a declared-but-unregistered mount is still reported rather
    than silently skipped.
  .PARAMETER Service
    Registry entry record built at script scope.
  .OUTPUTS
    Hashtables with Instance, Target, and IsConfigured keys.
  #>
  [CmdletBinding()]
  [OutputType([object[]])]
  param([Parameter(Mandatory)][hashtable]$Service)

  if (-not $Service.prefixMatch) {
    $target = if ($Service.type -eq 'windows-schtask') { $Service.taskPath } else { $Service.service }
    return @(@{ Instance = $Service.key; Target = $target; IsConfigured = $false })
  }

  $liveIds = @(Get-NucleusPrefixInstanceList -HostEntry $Service.hostEntry)
  $configuredIds = @(Get-NucleusConfiguredInstanceList -HostEntry $Service.hostEntry)
  $allIds = @($liveIds + $configuredIds | Sort-Object -Unique)

  return @($allIds | ForEach-Object {
      @{ Instance = $_; Target = $_; IsConfigured = ($configuredIds -contains $_) }
    })
}

# ── Not-loaded reporting ───────────────────────────────────────────────────
function Write-NotLoadedNotice {
  <#
  .SYNOPSIS
    Marks an instance as not-loaded and reports the transition once.
  .DESCRIPTION
    The health record carries the classification; its reported state is what
    suppresses repeat notices, so no separate marker file is written.
  .PARAMETER Instance
    Instance id.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Instance)

  Health-Init -Instance $Instance
  if ((Health-Get -Instance $Instance -Field 'state') -ne 'not-loaded') {
    Health-Set -Instance $Instance -Field 'state' -Value 'not-loaded'
  }
  if (-not (Health-IsReported -Instance $Instance -Expected 'not-loaded')) {
    Write-NucleusNotice -CommandName 'service-watchdog' -Message "$Instance is configured but not loaded"
    Health-MarkReported -Instance $Instance -State 'not-loaded'
  }
}

# ── Per-instance rule table ────────────────────────────────────────────────
function Test-ServiceInstance {
  <#
  .SYNOPSIS
    Applies the watchdog rule table to one instance.
  .PARAMETER Instance
    Instance id used as the key of the unified health record.
  .PARAMETER Target
    Supervisor target: an SCM service name, or a folder-qualified task id.
  .PARAMETER IsConfigured
    True when the user registry declares the instance but the current registry
    listing is what surfaced it.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Instance,
    [Parameter(Mandatory)][string]$Target,
    [Parameter(Mandatory)][bool]$IsConfigured
  )

  # Rule 1: user-disabled or not registered is not ours to start.
  if (-not (Supervisor-Enabled -Target $Target)) {
    if ($IsConfigured) { Write-NotLoadedNotice -Instance $Instance }
    return
  }

  # Rule 2: a blocked record must be reported, never revived.
  if (Health-IsBlocked -Instance $Instance) {
    $state = Health-Get -Instance $Instance -Field 'state'
    $class = Health-Get -Instance $Instance -Field 'class'
    $reported = "${state}:${class}"
    if (-not (Health-IsReported -Instance $Instance -Expected $reported)) {
      $remedy = Health-Get -Instance $Instance -Field 'remedy'
      Write-NucleusNotice -CommandName 'service-watchdog' -Message "$Instance is blocked ($class): $remedy"
      Health-MarkReported -Instance $Instance -State $reported
    }
    return
  }

  # Rule 4b: not-loaded record -> informational only (no action until nucleus-apply).
  # The record, not the probe, is the input: the classification is written by
  # whichever tick found the instance missing (Rule 1), and only nucleus-apply
  # re-arms it.  POSIX parity: service-watchdog.sh Rule 4b reads the same field
  # of the same unified record.  Without this branch Windows would start an
  # instance the POSIX watchdog deliberately leaves alone, and the "one shared
  # rule table" claim in the header would be false.
  $recordState = Health-Get -Instance $Instance -Field 'state'
  if ($recordState -eq 'not-loaded') {
    Write-NotLoadedNotice -Instance $Instance
    return
  }

  $isLive = Supervisor-Live -Target $Target
  $generation = Supervisor-Generation -Target $Target
  $lastExit = Supervisor-LastExit -Target $Target

  if ($isLive) {
    # The health record is the only place a restart is ever counted, and Rule 3
    # reads it, so the supervisor's generation token is folded in here.  A token
    # that changed between ticks means the supervisor started a new run; an
    # unchanged token means the instance survived the whole tick.
    $stored = Health-Get -Instance $Instance -Field 'generation'

    # A missing baseline means this is the first observation: adopt the token and
    # record nothing, so a cold start is never mistaken for a restart.  Only a
    # missing value counts as unobserved — a counter that legitimately reads zero
    # must still be compared, or a service's first restart would be swallowed.
    if ($null -ne $stored) {
      if ($generation -ne $stored) {
        # WHY: one restart per observed change, never (current - stored).  The
        # token is a run count on POSIX, but process identity or a run *time* on
        # Windows, where the difference is elapsed seconds and would fabricate
        # thousands of restarts out of a single one.
        Health-RecordRestart -Instance $Instance -Reason 'supervisor'
      } else {
        Health-RecordSuccess -Instance $Instance
      }
    }

    Health-Set -Instance $Instance -Field 'generation' -Value $generation
    Health-SetLastExit -Instance $Instance -ExitCode $lastExit

    # Rule 3: live but looping — break the loop, never restart it.
    if (Health-IsLooping -Instance $Instance) {
      Write-NucleusNotice -CommandName 'service-watchdog' -Message "$Instance is looping; stopping it"
      Health-SetBlocked -Instance $Instance -Class 'crash-loop' -Remedy 'restart-loop'
      Supervisor-Stop -Target $Target
      return
    }

    # Rule 5: live but broken — repair in place so it is not counted as a restart.
    if ($lastExit -eq 78) {
      Write-NucleusNotice -CommandName 'service-watchdog' -Message "$Instance exited 78 (EX_CONFIG); repairing it"
      $repairTimeout = Get-WatchdogLifecycleSeconds -Name 'watchdogRepairTimeoutSeconds' -Default 30
      $repairStatus = Invoke-BoundedRepair -Target $Target -TimeoutSeconds $repairTimeout
      if ($repairStatus -eq 124) {
        Write-NucleusWarning -CommandName 'service-watchdog' -Message "repair of $Instance timed out after ${repairTimeout}s"
      } elseif ($repairStatus -ne 0) {
        Write-NucleusWarning -CommandName 'service-watchdog' -Message "could not repair $Instance (status $repairStatus)"
      }
      return
    }

    return
  }

  # Rule 4: not live and not blocked — the only revival path.
  Write-NucleusNotice -CommandName 'service-watchdog' -Message "$Instance is not running; starting it"
  Supervisor-Start -Target $Target
}

# ── Declared lifecycle timings ─────────────────────────────────────────────
function Get-WatchdogLifecycleSeconds {
  <#
  .SYNOPSIS
    Reads one cloud-drive lifecycle timing from the service registry.
  .DESCRIPTION
    Both watchdog timings are declared once in services.json and are read here, so
    this watchdog cannot drift from the policy its POSIX twin reads out of the same
    file.  The two keys bound different things: watchdogTickSeconds bounds the gap
    BETWEEN ticks, watchdogRepairTimeoutSeconds bounds ONE repair call.
  .PARAMETER Name
    Lifecycle key to read.
  .PARAMETER Default
    Value to use when the registry does not declare the key.
  .OUTPUTS
    System.Int32
  #>
  [CmdletBinding()]
  [OutputType([int])]
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][int]$Default
  )

  # WHY stepwise instead of one chained index: `$RegistryRaw['cloud-drive'].lifecycle[$Name]`
  #   is evaluated left to right, and indexing $null THROWS ("Cannot index into a null
  #   array") — so the guard below could never run on the very path it exists for.  That
  #   made the declared default unreachable when the registry key, its lifecycle block,
  #   or $RegistryRaw itself is absent, while the POSIX twin reads the same two keys with
  #   a `${value:-<default>}` fallback and has always honoured it.
  $value = $null
  if ($null -ne $RegistryRaw) {
    $drive = $RegistryRaw['cloud-drive']
    if ($null -ne $drive) {
      $lifecycle = $drive['lifecycle']
      if ($null -ne $lifecycle) { $value = $lifecycle[$Name] }
    }
  }
  if (-not $value) { return $Default }
  return [int]$value
}

# ── Bounded repair ─────────────────────────────────────────────────────────
function Invoke-BoundedRepair {
  <#
  .SYNOPSIS
    Runs Supervisor-Repair under a wall-clock bound.
  .DESCRIPTION
    WHY a job: Windows has no timeout(1) and the SCM and task-scheduler cmdlets take
    no timeout of their own, so the bound is enforced by running the repair in a
    child job and abandoning it with Wait-Job.  This mirrors POSIX, where
    svc_run_bounded wraps the same call.  A repair that hangs would otherwise stall
    the whole tick, and every instance after it would go unchecked.
  .PARAMETER Target
    Folder-qualified task id or service name.
  .PARAMETER TimeoutSeconds
    Seconds allowed before the repair is abandoned.
  .OUTPUTS
    System.Int32 - 0 on success, 124 when the bound elapsed, 1 on failure.
  #>
  [CmdletBinding()]
  [OutputType([int])]
  param(
    [Parameter(Mandatory)][string]$Target,
    [Parameter(Mandatory)][int]$TimeoutSeconds
  )

  $adapter = switch ($script:LoadedSupervisorKind) {
    'scm' { 'Supervisor-Scm.ps1' }
    'schtask' { 'Supervisor-Schtask.ps1' }
    default { throw 'Invoke-BoundedRepair: no supervisor adapter is loaded' }
  }

  # WHY -ArgumentList instead of $using:: the child re-dot-sources the adapter, so it
  #   needs no value from this runspace and there is nothing for
  #   PSUseUsingScopeModifierInNewRunspaces to flag.
  $job = $null
  try {
    $job = Start-Job -ScriptBlock {
      param($AdapterPath, $RepairTarget)
      . $AdapterPath
      Supervisor-Repair -Target $RepairTarget
    } -ArgumentList (Join-Path $ModulesDir $adapter), $Target
  } catch {
    Write-NucleusWarning -CommandName 'service-watchdog' -Message "could not start a bounded repair for ${Target}: $($_.Exception.Message)"
    return 1
  }

  try {
    if (-not (Wait-Job -Job $job -Timeout $TimeoutSeconds)) {
      Stop-Job -Job $job
      return 124
    }
    if ($job.State -ne 'Completed') { return 1 }
    return 0
  } finally {
    Remove-Job -Job $job -Force
  }
}

# ── Main loop (persistent daemon pattern) ──────────────────────────────────
function Invoke-WatchdogIteration {
  <#
  .SYNOPSIS
    Runs the rule table once for every watchdog-managed instance.
  #>
  [CmdletBinding()]
  param()

  foreach ($svc in $Services) {
    $kind = Get-SupervisorKindForType -Type $svc.type
    if (-not $kind) {
      Write-NucleusInfo "unsupported type $($svc.type) for $($svc.key)"
      continue
    }
    Import-SupervisorAdapter -Kind $kind

    foreach ($target in (Get-InstanceTargetList -Service $svc)) {
      Test-ServiceInstance -Instance $target.Instance -Target $target.Target -IsConfigured $target.IsConfigured
    }
  }
}

if ($Oneshot) {
  Invoke-WatchdogIteration
} else {
  while ($true) {
    Invoke-WatchdogIteration
    Start-Sleep -Seconds (Get-WatchdogLifecycleSeconds -Name 'watchdogTickSeconds' -Default 300)
  }
}
