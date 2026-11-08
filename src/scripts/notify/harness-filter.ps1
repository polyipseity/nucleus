<#
.SYNOPSIS
  Turns a harness hook payload into that harness's native decision document by
  running the filters declared in the registry (Windows).

.DESCRIPTION
  Windows twin of harness-filter.sh. Reads the JSON hook payload on stdin and
  prints exactly one document, so one command serves every harness's hook
  definition:

    cursor           {"permission":"allow"|"ask"|"deny"}
    claude, copilot  {"hookSpecificOutput":{...,"permissionDecision":"..."}}
    pi, opencode,
    codex, others    plain allow | deny | ask

  The registry is `src\modules\configs\harness-filters.json` under
  $env:NUCLEUS_REPO_ROOT, which this file reads from the live checkout: the
  registry is data, and deployed copies live outside the repository.

  Filter protocol (one child process per enabled registry entry, in registry
  order):

    filters\<id>.ps1 --settings <json> --command <text>
    stdin   the raw hook payload, for a filter that needs more than the command
    stdout  exactly one line: decision<TAB>rule<TAB>reason

  A non-zero exit, a missing script, or a line without three tab-separated
  fields is recorded as ask with rule `filter-error`, because the filter could
  not state a verdict.

  The decisions aggregate as deny > ask > allow regardless of registry order, so
  registry order stays readable instead of load-bearing.  `ask` means "no
  decision here" and is then put to the configured approval sources, which
  answer allow or deny for a call no filter decides: the runner never allows by
  omission, because that would remove prompting the harness would otherwise do.
  The sources are consulted through the sibling harness-approval.ps1 with
  -Plain, so this runner renders the document and the resolver only states the
  decision.

  Every path prints a document and exits 0, because several harnesses read a
  failed hook as a denial, which would turn a broken registry into a blocked
  session.

.PARAMETER Harness
  Harness that called the hook (cursor, copilot, claude, opencode, pi, codex).

.EXAMPLE
  '{"command":"/bin/rm -rf x"}' | pwsh -NoProfile -File harness-filter.ps1 copilot

.NOTES
  Exit codes: always 0.

  Environment: NUCLEUS_REPO_ROOT locates the registry.
#>

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$Harness
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# WHY $PSScriptRoot: Windows deploys a copy of this script outside the repository,
# so the shared helpers are resolved beside the copy, never by a repo-relative path.
. (Join-Path -Path $PSScriptRoot -ChildPath 'harness-bridge-common.ps1')

function ConvertTo-HarnessFilterDocument {
  <#
  .SYNOPSIS
    Renders a decision in the calling harness's own vocabulary.
  .DESCRIPTION
    `ask` is valid in every shape, so the neutral answer is always expressible.
    The two document shapes are the ones the harnesses parse today (Copilot
    PreToolUse, Cursor beforeShellExecution); the plain word is what pi and
    opencode read from the last stdout line, and what a harness without a
    document shape ignores.
  .PARAMETER Harness
    Calling harness name.
  .PARAMETER Decision
    allow, ask, or deny.
  .PARAMETER Reason
    Human-readable reason, carried by the document shapes that have a field for it.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$Harness,

    [Parameter(Mandatory)]
    [ValidateSet('allow', 'ask', 'deny')]
    [string]$Decision,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Reason
  )

  switch ($Harness) {
    'cursor' {
      return (ConvertTo-Json -InputObject ([ordered]@{ permission = $Decision }) -Compress -Depth 5)
    }
    { $_ -in @('claude', 'copilot') } {
      return (ConvertTo-Json -InputObject ([ordered]@{
            hookSpecificOutput = [ordered]@{
              hookEventName             = 'PreToolUse'
              permissionDecision        = $Decision
              permissionDecisionReason  = $Reason
            }
          }) -Compress -Depth 5)
    }
    default { return $Decision }
  }
}

function Get-HarnessFilterRank {
  <#
  .SYNOPSIS
    Orders the decisions for aggregation.
  .PARAMETER Decision
    allow, ask, or deny.
  #>
  [CmdletBinding()]
  [OutputType([int])]
  param(
    [Parameter(Mandatory)]
    [string]$Decision
  )

  # WHY an ordered array instead of a switch: the ordering is data, not control
  # flow, so the index IS the rank and the least restrictive decision sits at the
  # head. An unknown decision falls back to that head rather than failing a hook.
  $order = @('allow', 'ask', 'deny')
  $index = [array]::IndexOf($order, $Decision)
  if ($index -lt 0) { $index = 0 }
  return $index
}

function Read-HarnessFilterPayloadCommand {
  <#
  .SYNOPSIS
    Extracts the shell command from a hook payload.
  .DESCRIPTION
    A PreToolUse hook fires for every tool and only a shell call carries a
    command, so a payload without one returns an empty string and the caller
    answers ask.
  .PARAMETER Payload
    Raw hook payload read from stdin.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Payload
  )

  if ([string]::IsNullOrWhiteSpace($Payload)) { return '' }
  if (-not $Payload.TrimStart().StartsWith('{')) { return $Payload }

  $parsed = $null
  try { $parsed = ConvertFrom-Json -InputObject $Payload -AsHashtable }
  catch { return '' }
  if ($parsed -isnot [hashtable]) { return '' }

  if ($parsed.ContainsKey('command') -and $parsed['command'] -is [string]) {
    return [string]$parsed['command']
  }
  if ($parsed.ContainsKey('tool_input') -and $parsed['tool_input'] -is [hashtable] -and $parsed['tool_input'].ContainsKey('command')) {
    return [string]$parsed['tool_input']['command']
  }
  return ''
}

function Read-HarnessFilterPayloadTool {
  <#
  .SYNOPSIS
    Extracts the tool name a hook payload reports.
  .DESCRIPTION
    Used when the filters leave a call undecided, so the approval gate shows the
    tool the harness named. A payload this cannot read names no tool, and the
    gate still has to be asked.
  .PARAMETER Payload
    Raw hook payload read from stdin.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Payload
  )

  $fallback = 'hook'
  if ([string]::IsNullOrWhiteSpace($Payload)) { return $fallback }
  if (-not $Payload.TrimStart().StartsWith('{')) { return $fallback }

  $parsed = $null
  try { $parsed = ConvertFrom-Json -InputObject $Payload -AsHashtable }
  catch { return $fallback }
  if ($parsed -isnot [hashtable]) { return $fallback }

  foreach ($field in @('tool_name', 'tool', 'hook_event_name')) {
    if ($parsed.ContainsKey($field) -and -not [string]::IsNullOrWhiteSpace([string]$parsed[$field])) {
      return [string]$parsed[$field]
    }
  }
  return $fallback
}

function Get-HarnessFilterRegistryEntry {
  <#
  .SYNOPSIS
    Reads the enabled registry entries in registry order.
  .PARAMETER RegistryPath
    Absolute path to harness-filters.json.
  #>
  [CmdletBinding()]
  [OutputType([array])]
  param(
    [Parameter(Mandatory)]
    [string]$RegistryPath
  )

  $document = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $RegistryPath -Raw -Encoding UTF8) -AsHashtable
  if ($document -isnot [hashtable] -or -not $document.ContainsKey('filters')) {
    throw 'the filter registry carries no filters array'
  }

  $entries = @(
    foreach ($entry in @($document['filters'])) {
      if ($entry -isnot [hashtable]) { continue }
      if (-not $entry.ContainsKey('enabled') -or $entry['enabled'] -ne $true) { continue }
      $settings = if ($entry.ContainsKey('settings')) { $entry['settings'] } else { [ordered]@{} }
      [pscustomobject]@{
        Id       = [string]$entry['id']
        Settings = (ConvertTo-Json -InputObject $settings -Compress -Depth 10)
      }
    }
  )
  return , @($entries)
}

function Invoke-HarnessFilterList {
  <#
  .SYNOPSIS
    Runs every enabled filter and aggregates the decisions.
  .DESCRIPTION
    Each filter is a child process so a filter that crashes or exits cannot take
    the runner with it, which is also how the POSIX twin behaves.
  .PARAMETER Entry
    Registry entries in registry order.
  .PARAMETER Command
    Extracted shell command.
  .PARAMETER Payload
    Raw hook payload, passed to each filter on stdin.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)]
    # WHY AllowEmptyCollection: a registry that enables no filter is a valid
    # registry, and it must answer ask rather than fail parameter binding.
    [AllowEmptyCollection()]
    [array]$Entry,

    [Parameter(Mandatory)]
    [string]$Command,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Payload
  )

  $pwshPath = [Environment]::ProcessPath
  $filterDir = Join-Path -Path $PSScriptRoot -ChildPath 'filters'
  # WHY an empty Decision: "no filter spoke" is not a verdict. The caller answers
  # ask for it, while a filter that allows deliberately still outranks it.
  $best = @{ Decision = ''; Reason = '' }

  foreach ($item in $Entry) {
    $filterPath = Join-Path -Path $filterDir -ChildPath "$($item.Id).ps1"
    $line = ''
    if (-not (Test-Path -LiteralPath $filterPath -PathType Leaf)) {
      $line = "ask`tfilter-error`tno filter script at $filterPath"
    }
    else {
      # WHY no 2>&1: stderr stays off the verdict path, matching the POSIX twin.
      # A child's diagnostic carries whatever text it likes, and merging it would
      # let that text read as the filter's answer.
      $output = @($Payload | & $pwshPath -NoProfile -File $filterPath --settings $item.Settings --command $Command)
      $exitCode = $LASTEXITCODE
      $candidate = @($output | ForEach-Object { [string]$_ } | Where-Object { $_ -ne '' })
      if ($exitCode -ne 0) {
        $line = 'ask' + "`t" + 'filter-error' + "`t" + 'the filter exited non-zero'
      }
      elseif ($candidate.Count -ne 1 -or ($candidate[0] -split "`t").Count -ne 3) {
        $line = 'ask' + "`t" + 'filter-error' + "`t" + 'the filter printed no decision line'
      }
      else { $line = $candidate[0] }
    }

    $fields = $line -split "`t"
    $decision = $fields[0]
    # WHY -cnotin: PowerShell's -in folds case, so an uppercase decision would
    # survive normalization, then lose the case-sensitive rank lookup, and read as
    # allow. The POSIX twin answers ask for the same bytes.
    if ($decision -cnotin @('allow', 'ask', 'deny')) { $decision = 'ask' }
    if ([string]::IsNullOrEmpty($best.Decision) -or
      (Get-HarnessFilterRank -Decision $decision) -gt (Get-HarnessFilterRank -Decision $best.Decision)) {
      $best = @{ Decision = $decision; Reason = "$($item.Id) ($($fields[1])): $($fields[2])" }
    }
  }
  return $best
}

function Complete-HarnessFilter {
  <#
  .SYNOPSIS
    Prints the aggregated decision in the caller's vocabulary and exits 0.
  .DESCRIPTION
    An undecided call is put to the configured approval sources, asked for the
    decision word alone because this runner renders the document. A source that
    answers allow or deny becomes the runner's answer; anything else keeps the
    runner's own reason so the harness's prompt explains what happened.
  .PARAMETER Harness
    Calling harness name.
  .PARAMETER Decision
    allow, ask, or deny.
  .PARAMETER Reason
    Human-readable reason.
  .PARAMETER Tool
    Tool name, for the approval gate.
  .PARAMETER Summary
    One-line description of the call, for the approval gate.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Harness,

    [Parameter(Mandatory)]
    [string]$Decision,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Reason,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Tool,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Summary
  )

  if ($Decision -cin @('allow', 'deny')) {
    Write-Output (ConvertTo-HarnessFilterDocument -Harness $Harness -Decision $Decision -Reason $Reason)
    exit 0
  }

  $resolverPath = Join-Path -Path $PSScriptRoot -ChildPath 'harness-approval.ps1'
  if (-not (Test-Path -LiteralPath $resolverPath -PathType Leaf)) {
    Write-HarnessBridgeWarning -CommandName 'harness-filter' -Message "no approval resolver at ${resolverPath}: asking locally"
  }
  else {
    $pwshPath = [Environment]::ProcessPath
    $lines = @(& $pwshPath -NoProfile -File $resolverPath -Plain -Harness $Harness -Tool $Tool -Summary $Summary |
        ForEach-Object { [string]$_ } | Where-Object { $_ -ne '' })
    if ($LASTEXITCODE -ne 0) {
      Write-HarnessBridgeWarning -CommandName 'harness-filter' -Message 'the approval resolver failed: asking locally'
    }
    elseif ($lines.Count -ge 1 -and $lines[$lines.Count - 1] -cin @('allow', 'deny')) {
      Write-Output (ConvertTo-HarnessFilterDocument -Harness $Harness -Decision $lines[$lines.Count - 1] -Reason 'harness-approval (source)')
      exit 0
    }
  }

  Write-Output (ConvertTo-HarnessFilterDocument -Harness $Harness -Decision 'ask' -Reason $Reason)
  exit 0
}

try {
  $payload = ''
  if ([Console]::IsInputRedirected) { $payload = [Console]::In.ReadToEnd() }

  # What the approval gate shows the user when no filter decides, so a call no
  # filter claims still reaches the gate with the tool and the command it saw.
  $toolName = Read-HarnessFilterPayloadTool -Payload $payload
  $summaryText = (($payload -replace '\s+', ' ').Trim())
  if ($summaryText.Length -gt 200) { $summaryText = $summaryText.Substring(0, 200) }

  if ([string]::IsNullOrWhiteSpace($env:NUCLEUS_REPO_ROOT)) {
    Write-HarnessBridgeWarning -CommandName 'harness-filter' -Message 'NUCLEUS_REPO_ROOT is unset: asking locally'
    Complete-HarnessFilter -Harness $Harness -Decision 'ask' -Tool $toolName -Summary $summaryText -Reason 'harness-filter (registry-error): NUCLEUS_REPO_ROOT is unset, so the filter registry cannot be read'
  }
  # check-suppress:config-method: method 4 (runtime direct read) -- the registry is data the runner reads from the live checkout, so a writable symlink into the store or the home directory would freeze the filter list until the next apply
  $registryPath = Join-Path -Path (Join-Path -Path (Join-Path -Path $env:NUCLEUS_REPO_ROOT -ChildPath 'src') -ChildPath 'modules') -ChildPath 'configs/harness-filters.json'
  if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
    Write-HarnessBridgeWarning -CommandName 'harness-filter' -Message "filter registry not found at ${registryPath}: asking locally"
    Complete-HarnessFilter -Harness $Harness -Decision 'ask' -Tool $toolName -Summary $summaryText -Reason "harness-filter (registry-error): no filter registry at $registryPath"
  }

  try { $entries = Get-HarnessFilterRegistryEntry -RegistryPath $registryPath }
  catch {
    Write-HarnessBridgeWarning -CommandName 'harness-filter' -Message "could not parse the filter registry at ${registryPath}: asking locally"
    Complete-HarnessFilter -Harness $Harness -Decision 'ask' -Tool $toolName -Summary $summaryText -Reason "harness-filter (registry-error): the filter registry at $registryPath is unreadable"
  }

  $command = Read-HarnessFilterPayloadCommand -Payload $payload
  if ([string]::IsNullOrWhiteSpace($command)) {
    Complete-HarnessFilter -Harness $Harness -Decision 'ask' -Tool $toolName -Summary $summaryText -Reason 'harness-filter (not-a-command): the payload carries no shell command'
  }
  # The command is what the gate asks about, so it replaces the raw payload.
  $summaryText = $command

  $result = Invoke-HarnessFilterList -Entry $entries -Command $command -Payload $payload
  # WHY ask and never allow: an undecided call is not an authorisation, so the
  # runner allows only when a filter says so.
  if ([string]::IsNullOrEmpty($result.Decision)) {
    Complete-HarnessFilter -Harness $Harness -Decision 'ask' -Tool $toolName -Summary $summaryText -Reason 'harness-filter (no-filter): no enabled filter produced a verdict'
  }
  Complete-HarnessFilter -Harness $Harness -Decision $result.Decision -Tool $toolName -Summary $summaryText -Reason $result.Reason
}
catch {
  # Fail open to the harness's own prompt: a broken runner must not authorise a
  # call, and must not block one either.
  Write-HarnessBridgeWarning -CommandName 'harness-filter' -Message $_.Exception.Message
  Write-Output (ConvertTo-HarnessFilterDocument -Harness $Harness -Decision 'ask' -Reason 'harness-filter (runner-error): the runner failed, so the harness prompts')
}

exit 0
