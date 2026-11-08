<#
.SYNOPSIS
  Shared helpers for the Windows harness-bridge entry points.

.DESCRIPTION
  harness-notify.ps1, harness-approval.ps1, and harness-drive.ps1 each dot-source
  this file, so the warning line, the nucleus root, and the runtime config path
  have one definition.

  The entry points are deployed verbatim to <USER root>\bin and reached from
  harness hooks through the %USERPROFILE%\.local\bin\*.cmd shims, and this file
  is copied beside them by Sync-HarnessBridge.  That is also why no helper here
  imports Format-NucleusOutput.psm1 from $PSScriptRoot: a repository-relative path
  would not exist in the deployed copy.  Data that only the live checkout owns is
  reached through $env:NUCLEUS_REPO_ROOT instead, exactly as harness-filter.ps1
  reads its registry.  This file is never invoked as a command, so it gets no shim.

  Warning output keeps the F1 shape (`<cmd>: warning: <msg>`) on stderr minus
  console color, which a hook never sees anyway.
#>

function Write-HarnessBridgeWarning {
  <#
  .SYNOPSIS
    Writes one F1 warning line to stderr without importing the shared module.
  .DESCRIPTION
    See the file header: this helper is deployed outside the repository, so it
    cannot import Format-NucleusOutput.psm1.  The line keeps the F1 shape minus
    console color, which a hook never sees anyway.
  .PARAMETER CommandName
    F1 command prefix.
  .PARAMETER Message
    Warning text.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$CommandName,

    [Parameter(Mandatory)]
    [string]$Message
  )

  [Console]::Error.WriteLine("${CommandName}: warning: $Message")
}

function Get-HarnessBridgeUserRoot {
  <#
  .SYNOPSIS
    Resolves the Windows nucleus USER root.
  .DESCRIPTION
    Mirrors Get-NucleusUserRoot in ManagedPaths.ps1, inlined because the entry
    points are deployed outside the repository.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    throw '%LOCALAPPDATA% is unset; the nucleus USER root is undefined'
  }
  return (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'nucleus')
}

function Get-HarnessBridgeConfigPath {
  <#
  .SYNOPSIS
    Resolves the nucleus runtime config path.
  .DESCRIPTION
    Same location `scripts/config.ps1` (nucleus-config) reads and writes.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  return (Join-Path -Path $HOME -ChildPath '.local/state/nucleus/config.json')
}

function Get-HarnessBridgeDigest {
  <#
  .SYNOPSIS
    First 16 hex characters of the SHA-256 of the given text.
  .DESCRIPTION
    The audit schema keeps a short fingerprint of the input a decision was made
    over, so a later review can tell two otherwise identical decisions apart
    without storing the payload.
  .PARAMETER Text
    Raw input the decision was made over.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Text
  )

  $algorithm = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = $algorithm.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
  }
  finally {
    $algorithm.Dispose()
  }
  $hex = -join ($hash | ForEach-Object { $_.ToString('x2') })
  return $hex.Substring(0, 16)
}

function Write-HarnessBridgeAuditEvent {
  <#
  .SYNOPSIS
    Appends one harness-bridge event to the shared nucleus audit log.
  .DESCRIPTION
    Every bridge decision is recorded through nucleus-logs, which owns the log
    root, the line format, and the append, so a hook cannot drift from the log
    the gate reads.  The entry script runs as a child process because the
    deployed copies live outside the repository and the app's own modules do not
    travel with them.

    Best-effort by contract: this function throws, and every caller catches and
    warns, because a logging failure must never change a decision or suppress the
    document the harness reads.
  .PARAMETER Kind
    Event kind: approval, notify, or filter.
  .PARAMETER Harness
    Harness that asked.
  .PARAMETER Decision
    allow, deny, ask, or empty when no decision applies.
  .PARAMETER Source
    What decided: prompt, hermes, filter, or none.
  .PARAMETER Filter
    Filter id when a registry filter produced the verdict.
  .PARAMETER Rule
    Rule id inside that filter, or the runner-level rule name.
  .PARAMETER Summary
    One-line description of the call or the event.
  .PARAMETER Digest
    Short fingerprint of the raw input.
  .PARAMETER StartTime
    When the entry point started, so the event carries its latency.
  .PARAMETER Id
    Event id; empty lets nucleus-logs carry no id of its own.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Kind,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Harness,

    [AllowEmptyString()]
    [string]$Decision = '',

    [AllowEmptyString()]
    [string]$Source = 'none',

    [AllowEmptyString()]
    [string]$Filter = '',

    [AllowEmptyString()]
    [string]$Rule = '',

    [AllowEmptyString()]
    [string]$Summary = '',

    [AllowEmptyString()]
    [string]$Digest = '',

    [datetime]$StartTime = [datetime]::UtcNow,

    [AllowEmptyString()]
    [string]$Id = ''
  )

  # WHY here: the schema caps a summary at 200 collapsed characters, and one place
  # per platform owns the rule, so no caller can widen it by passing a raw body.
  $Summary = ($Summary -replace '\s+', ' ').Trim()
  if ($Summary.Length -gt 200) { $Summary = $Summary.Substring(0, 200) }
  # WHY mint: the review workflow labels an event by id, so every event needs one
  # even when no caller has a natural id to hand.
  if ([string]::IsNullOrEmpty($Id)) { $Id = [guid]::NewGuid().ToString('N').Substring(0, 8) }

  $auditEvent = @{ kind = $Kind }
  # WHY none: a bridge event always names what decided, and no decision names itself.
  $auditEvent['source'] = if ([string]::IsNullOrEmpty($Source)) { 'none' } else { $Source }
  foreach ($pair in @(
      @{ Key = 'harness'; Value = $Harness },
      @{ Key = 'decision'; Value = $Decision },
      @{ Key = 'filter'; Value = $Filter },
      @{ Key = 'rule'; Value = $Rule },
      @{ Key = 'summary'; Value = $Summary },
      @{ Key = 'digest'; Value = $Digest },
      @{ Key = 'id'; Value = $Id }
    )) {
    # WHY empty means absent: the schema writes an absent field as null, and ""
    # would be a different value for the same absence.
    if (-not [string]::IsNullOrEmpty($pair.Value)) { $auditEvent[$pair.Key] = $pair.Value }
  }
  $latency = [int]([datetime]::UtcNow - $StartTime).TotalMilliseconds
  $auditEvent['latency_ms'] = $latency

  $repoRoot = $env:NUCLEUS_REPO_ROOT
  if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    throw 'NUCLEUS_REPO_ROOT is unset, so the nucleus-logs entry cannot be resolved'
  }
  $logsPath = Join-Path -Path (Join-Path -Path $repoRoot -ChildPath 'scripts') -ChildPath 'logs.ps1'
  if (-not (Test-Path -LiteralPath $logsPath -PathType Leaf)) {
    throw "nucleus-logs entry not found at $logsPath"
  }

  $json = ConvertTo-Json -InputObject $auditEvent -Compress -Depth 5
  $pwshPath = [Environment]::ProcessPath
  $output = @($json | & $pwshPath -NoProfile -File $logsPath append -Log harness)
  if ($LASTEXITCODE -ne 0) {
    throw "nucleus-logs append failed (exit $LASTEXITCODE): $($output -join ' ')"
  }
}
