<#
.SYNOPSIS
  Turns a harness hook payload into that harness's native decision document by
  running the filters declared in the registry (Windows).

.DESCRIPTION
  Windows twin of decide-call.sh. Reads the JSON hook payload on stdin and
  prints exactly one document, so one command serves every harness's hook
  definition:

    cursor           {"permission":"allow"|"ask"|"deny"}
    claude, copilot  {"hookSpecificOutput":{...,"permissionDecision":"..."}}
    pi, opencode,
    codex, others    the typed decision document itself

  The registry is `src\modules\configs\harness-filters.json` under
  $env:NUCLEUS_REPO_ROOT, which this file reads from the live checkout: the
  registry is data, and deployed copies live outside the repository.

  Filter protocol (one child process per enabled registry entry, in registry
  order):

    bun filters\<id>.ts --settings <json> --command <text>
    stdin   the raw hook payload, for a filter that needs more than the command
    stdout  exactly one non-empty line: decision<TAB>rule<TAB>reason

  A missing bun, a missing filter, a non-zero exit, or an output that is not
  exactly one non-empty line carrying three tab-separated fields is recorded as
  ask with rule `filter-error`, because the filter could not state a verdict.

  WHY bun and one file per filter instead of a PowerShell twin: the POSIX twin
  runs the same `filters/<id>.ts` through the same runtime, so one program decides
  for every harness on every host and no pair of implementations can drift.

  The decisions aggregate as deny > ask > allow regardless of registry order, so
  registry order stays readable instead of load-bearing.  `ask` means "no
  decision here" and is then put to the configured approval sources, which
  answer allow or deny for a call no filter decides: the runner never allows by
  omission, because that would remove prompting the harness would otherwise do.
  The sources are consulted through the sibling request-approval.ps1, which
  prints one typed decision document. This runner validates it and renders it in
  the calling harness's vocabulary.

  Every path prints a document and exits 0, because several harnesses read a
  failed hook as a denial, which would turn a broken registry into a blocked
  session.

.PARAMETER Harness
  Harness that called the hook (cursor, copilot, claude, opencode, pi, codex).

.EXAMPLE
  '{"command":"/bin/rm -rf x"}' | pwsh -NoProfile -File decide-call.ps1 copilot

.NOTES
  Exit codes: always 0.

  Environment: NUCLEUS_REPO_ROOT locates the registry.
#>


[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$Harness
)

. (Join-Path $PSScriptRoot '..\..\lib\pwsh-guard.ps1')
Assert-NucleusPowerShell -Minimum '7.0'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# WHY $PSScriptRoot: Windows deploys a copy of this script outside the repository,
# so the shared helpers are resolved beside the copy, never by a repo-relative path.
. (Join-Path -Path $PSScriptRoot -ChildPath '../harness-bridge-common.ps1')

# WHY script scope: the runner records its verdict at the single exit it funnels
# through, so the start time, the input fingerprint, and the filter that spoke
# are collected here as the run produces them.
$script:auditStart = [datetime]::UtcNow
$script:auditDigest = ''
$script:filterId = ''
$script:filterRule = ''

function Format-HarnessDecisionDocument {
  <#
  .SYNOPSIS
    Builds the typed decision document shared by every harness adapter.
  .DESCRIPTION
    Filter decisions have no approval source, so the source is `none` and no
    source timed out. The timeout values are the contract bounds from the
    decision schema, not caller-supplied waits.
  .PARAMETER Decision
    allow, ask, or deny.
  .PARAMETER Reason
    Why the runner answered this way.
  .PARAMETER Source
    Approval source, or `none` when no source decided.
  .PARAMETER TimedOutSources
    Sources that gave up waiting.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [ValidateSet('allow', 'ask', 'deny')]
    [string]$Decision,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Reason,

    [string]$Source = 'none',

    [string[]]$TimedOutSources = @()
  )

  $document = [ordered]@{
    version         = 1
    decision        = $Decision
    reason          = $Reason
    source          = $Source
    timeouts        = [ordered]@{ hermes = 300; prompt = 600 }
    timedOutSources = @($TimedOutSources | Sort-Object -Unique)
  }
  return (ConvertTo-Json -InputObject $document -Compress -Depth 5)
}

function Read-HarnessDecisionDocument {
  <#
  .SYNOPSIS
    Validates the resolver's typed document and returns its compact form.
  .DESCRIPTION
    An empty return means the text is not a decision the harness can act on.
    Every field from decision-contract.schema.json is checked here; the runner
    never falls back to a plain word or to a stderr detail.
  .PARAMETER Text
    Raw stdout captured from the approval resolver.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Text
  )

  $parsed = $null
  try { $parsed = ConvertFrom-Json -InputObject $Text -AsHashtable -ErrorAction Stop }
  catch { return '' }
  if ($parsed -isnot [hashtable]) { return '' }
  # decision-contract.schema.json sets additionalProperties: false at the top
  # level, so an extra field makes the whole document unusable.
  $contractKeys = @('version', 'decision', 'reason', 'source', 'timeouts', 'timedOutSources')
  if (@($parsed.Keys).Count -ne $contractKeys.Count) { return '' }
  foreach ($key in $contractKeys) {
    if ($parsed.Keys -cnotcontains $key) { return '' }
  }
  if ($parsed['version'] -ne 1) { return '' }
  if ($parsed['decision'] -cnotin @('allow', 'ask', 'deny')) { return '' }
  if ($parsed['reason'] -isnot [string]) { return '' }
  if ($parsed['source'] -cnotin @('prompt', 'hermes', 'all-timeouts', 'resolver-error', 'none')) { return '' }
  $timeouts = $parsed['timeouts']
  if ($timeouts -isnot [hashtable] -or $timeouts['hermes'] -ne 300 -or $timeouts['prompt'] -ne 600) { return '' }
  $timedOut = $parsed['timedOutSources']
  if ($timedOut -isnot [array]) { return '' }
  foreach ($name in $timedOut) {
    if ($name -cnotin @('hermes', 'prompt')) { return '' }
  }
  return (ConvertTo-Json -InputObject $parsed -Compress -Depth 5)
}

function ConvertTo-HarnessFilterDocument {
  <#
  .SYNOPSIS
    Renders a typed decision in the calling harness's own vocabulary.
  .DESCRIPTION
    `ask` is valid in every shape, so the neutral answer is always expressible.
    The two document shapes are the ones the harnesses parse today (Copilot
    PreToolUse, Cursor beforeShellExecution); every other harness reads the typed
    document itself, reason included.
  .PARAMETER Harness
    Calling harness name.
  .PARAMETER Document
    Typed decision document.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$Harness,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Document
  )

  $parsed = ConvertFrom-Json -InputObject $Document -AsHashtable
  $decision = [string]$parsed['decision']
  $reason = [string]$parsed['reason']
  switch ($Harness) {
    'cursor' {
      return (ConvertTo-Json -InputObject ([ordered]@{ permission = $decision }) -Compress -Depth 5)
    }
    { $_ -in @('claude', 'copilot') } {
      return (ConvertTo-Json -InputObject ([ordered]@{
            hookSpecificOutput = [ordered]@{
              hookEventName             = 'PreToolUse'
              permissionDecision        = $decision
              permissionDecisionReason  = $reason
            }
          }) -Compress -Depth 5)
    }
    default { return $Document }
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
  .DESCRIPTION
    Returns one object per enabled entry, carrying the id and its settings as JSON.
  .PARAMETER RegistryPath
    Absolute path to harness-filters.json.
  #>
  [CmdletBinding()]
  # WHY object[]: the entries are [pscustomobject] values collected from a
  # pipeline, so the emitted array is System.Object[] and the declaration says so.
  [OutputType([object[]])]
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

  $filterDir = Join-Path -Path $PSScriptRoot -ChildPath '../filters'
  # WHY an empty Decision: "no filter spoke" is not a verdict. The caller answers
  # ask for it, while a filter that allows deliberately still outranks it.
  $best = @{ Decision = ''; Reason = ''; Filter = ''; Rule = '' }

  # check-suppress:suppression_doc: bun may be absent; that absence is the expected case, and the loop answers it as ask filter-error
  $bunCommand = Get-Command -Name 'bun' -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($null -eq $bunCommand) {
    # WHY a warning and not a throw: a missing runtime must not abort the hook,
    # and this line is what reaches a human, matching the POSIX twin.
    Write-HarnessBridgeWarning -CommandName 'decide-call' -Message 'bun is not on PATH, so no filter can run: asking locally'
  }

  foreach ($item in $Entry) {
    $filterPath = Join-Path -Path $filterDir -ChildPath "$($item.Id).ts"
    $line = ''
    if ($null -eq $bunCommand) {
      $line = "ask`tfilter-error`tbun is not on PATH, so the filter runtime is missing"
    }
    elseif (-not (Test-Path -LiteralPath $filterPath -PathType Leaf)) {
      $line = "ask`tfilter-error`tno filter script at $filterPath"
    }
    else {
      # WHY no 2>&1: stderr stays off the verdict path, matching the POSIX twin.
      # A child's diagnostic carries whatever text it likes, and merging it would
      # let that text read as the filter's answer.
      $output = @($Payload | & $bunCommand.Source run $filterPath --settings $item.Settings --command $Command)
      $exitCode = $LASTEXITCODE
      # WHY empty strings dropped: a blank line ahead of the verdict is not
      # content, so the count is of verdict lines. The POSIX twin drops the same
      # lines with sed before it counts.
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
      $best = @{
        Decision = $decision
        Reason   = "$($item.Id) ($($fields[1])): $($fields[2])"
        Filter   = [string]$item.Id
        Rule     = [string]$fields[1]
      }
    }
  }
  return $best
}

function Write-HarnessFilterAudit {
  <#
  .SYNOPSIS
    Records one filter verdict in the shared audit log.
  .DESCRIPTION
    Best-effort and first: the verdict decides whether a command runs, so a failed
    append is reported and then ignored. The filter that spoke (if any) and its
    rule are what makes filter accuracy auditable later.
  .PARAMETER Harness
    Calling harness name.
  .PARAMETER Decision
    allow, deny, or ask.
  .PARAMETER Rule
    Runner-level rule name; empty means the deciding filter's own rule applies.
  .PARAMETER Summary
    One-line description of the call.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Harness,

    [Parameter(Mandatory)]
    [string]$Decision,

    [AllowEmptyString()]
    [string]$Rule = '',

    [AllowEmptyString()]
    [string]$Summary = ''
  )

  $effectiveRule = if ([string]::IsNullOrEmpty($Rule)) { $script:filterRule } else { $Rule }
  $auditSource = if ([string]::IsNullOrEmpty($script:filterId)) { 'none' } else { 'filter' }
  try {
    Write-HarnessBridgeAuditEvent -Kind 'filter' -Harness $Harness -Decision $Decision `
      -Source $auditSource -Filter $script:filterId -Rule $effectiveRule `
      -Summary $Summary -Digest $script:auditDigest -StartTime $script:auditStart
  }
  catch {
    Write-HarnessBridgeWarning -CommandName 'decide-call' -Message "could not write the harness audit log: $($_.Exception.Message)"
  }
}

function Complete-HarnessFilter {
  <#
  .SYNOPSIS
    Prints the aggregated decision in the caller's vocabulary and exits 0.
  .DESCRIPTION
    An undecided call is put to the configured approval sources. A valid typed
    document becomes the runner's answer; anything else keeps the runner's own
    ask so the harness's prompt explains what happened.
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
  .PARAMETER Rule
    Runner-level rule name, so an audited ask names what stopped it deciding.
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
    [string]$Summary,

    [AllowEmptyString()]
    [string]$Rule = ''
  )

  Write-HarnessFilterAudit -Harness $Harness -Decision $Decision -Rule $Rule -Summary $Summary

  $document = Format-HarnessDecisionDocument -Decision $Decision -Reason $Reason
  if ($Decision -cin @('allow', 'deny')) {
    Write-Output (ConvertTo-HarnessFilterDocument -Harness $Harness -Document $document)
    exit 0
  }

  # No filter decided, so the configured approval sources answer. Their document
  # carries the reason, which is what the harness prompt has to show.
  $resolverPath = Join-Path -Path $PSScriptRoot -ChildPath 'request-approval.ps1'
  if (-not (Test-Path -LiteralPath $resolverPath -PathType Leaf)) {
    Write-HarnessBridgeWarning -CommandName 'decide-call' -Message "no approval resolver at ${resolverPath}: asking locally"
  }
  else {
    $pwshPath = [Environment]::ProcessPath
    $lines = @(& $pwshPath -NoProfile -File $resolverPath -Harness $Harness -Tool $Tool -Summary $Summary |
        ForEach-Object { [string]$_ } | Where-Object { $_ -ne '' })
    if ($LASTEXITCODE -ne 0) {
      Write-HarnessBridgeWarning -CommandName 'decide-call' -Message 'the approval resolver failed: asking locally'
    }
    else {
      $resolved = Read-HarnessDecisionDocument -Text ($lines -join "`n")
      if ($resolved -eq '') {
        Write-HarnessBridgeWarning -CommandName 'decide-call' -Message 'the approval resolver printed no valid decision document: asking locally'
      }
      else {
        $resolvedDocument = ConvertFrom-Json -InputObject $resolved -AsHashtable
        # A source decided, so its reason is the one the harness prompt shows.
        # An ask means no source answered; the runner's own reason then explains
        # why it is prompting (filter-error, no-filter, or not-a-command).
        if ($resolvedDocument['decision'] -cne 'ask') {
          Write-Output (ConvertTo-HarnessFilterDocument -Harness $Harness -Document $resolved)
          exit 0
        }
      }
    }
  }

  Write-Output (ConvertTo-HarnessFilterDocument -Harness $Harness -Document $document)
  exit 0
}

try {
  $payload = ''
  if ([Console]::IsInputRedirected) { $payload = [Console]::In.ReadToEnd() }
  $script:auditDigest = Get-HarnessBridgeDigest -Text $payload

  # Record sandbox state for this harness so a transition seen by one agent is
  # reported to the next. Best-effort: recording must never affect the filter
  # decision.
  if (-not [string]::IsNullOrEmpty($Harness)) {
    try {
      $utilsPath = Join-Path -Path $PSScriptRoot -ChildPath '../../../../scripts/utils.ps1'
      if (Test-Path -LiteralPath $utilsPath -PathType Leaf) {
        $pwshPath = [Environment]::ProcessPath
        $null = $payload | & $pwshPath -NoProfile -File $utilsPath harness report-sandbox $Harness --format check  # check-suppress:suppression_doc: sandbox-context recording is best-effort and must not change the filter decision
      } elseif (Get-Command -Name 'nucleus-utils' -ErrorAction SilentlyContinue) {
        $null = $payload | & nucleus-utils harness report-sandbox $Harness --format check  # check-suppress:suppression_doc: sandbox-context recording is best-effort and must not change the filter decision
      }
    } catch {
      # check-suppress:suppression_doc: sandbox-context recording is best-effort and must not change the filter decision
      $null = $_
    }
  }

  # What the approval gate shows the user when no filter decides, so a call no
  # filter claims still reaches the gate with the tool and the command it saw.
  $toolName = Read-HarnessFilterPayloadTool -Payload $payload
  $summaryText = (($payload -replace '\s+', ' ').Trim())
  if ($summaryText.Length -gt 200) { $summaryText = $summaryText.Substring(0, 200) }

  if ([string]::IsNullOrWhiteSpace($env:NUCLEUS_REPO_ROOT)) {
    Write-HarnessBridgeWarning -CommandName 'decide-call' -Message 'NUCLEUS_REPO_ROOT is unset: asking locally'
    Complete-HarnessFilter -Harness $Harness -Decision 'ask' -Tool $toolName -Summary $summaryText -Reason 'nucleus-utils harness decide-call (registry-error): NUCLEUS_REPO_ROOT is unset, so the filter registry cannot be read' -Rule registry-error
  }
  # check-suppress:config-method: method 4 (runtime direct read) -- the registry is data the runner reads from the live checkout, so a writable symlink into the store or the home directory would freeze the filter list until the next apply
  $registryPath = Join-Path -Path (Join-Path -Path (Join-Path -Path $env:NUCLEUS_REPO_ROOT -ChildPath 'src') -ChildPath 'modules') -ChildPath 'configs/harness-filters.json'
  if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
    Write-HarnessBridgeWarning -CommandName 'decide-call' -Message "filter registry not found at ${registryPath}: asking locally"
    Complete-HarnessFilter -Harness $Harness -Decision 'ask' -Tool $toolName -Summary $summaryText -Reason "nucleus-utils harness decide-call (registry-error): no filter registry at $registryPath" -Rule registry-error
  }

  try { $entries = Get-HarnessFilterRegistryEntry -RegistryPath $registryPath }
  catch {
    Write-HarnessBridgeWarning -CommandName 'decide-call' -Message "could not parse the filter registry at ${registryPath}: asking locally"
    Complete-HarnessFilter -Harness $Harness -Decision 'ask' -Tool $toolName -Summary $summaryText -Reason "nucleus-utils harness decide-call (registry-error): the filter registry at $registryPath is unreadable" -Rule registry-error
  }

  $command = Read-HarnessFilterPayloadCommand -Payload $payload
  if ([string]::IsNullOrWhiteSpace($command)) {
    Complete-HarnessFilter -Harness $Harness -Decision 'ask' -Tool $toolName -Summary $summaryText -Reason 'nucleus-utils harness decide-call (not-a-command): the payload carries no shell command' -Rule not-a-command
  }
  # The command is what the gate asks about, so it replaces the raw payload, and it
  # is collapsed to the one line the terminal prompt and the audit line carry: a
  # multi-line command would otherwise reach both verbatim.
  $summaryText = (($command -replace '\s+', ' ').Trim())
  if ($summaryText.Length -gt 200) { $summaryText = $summaryText.Substring(0, 200) }

  $result = Invoke-HarnessFilterList -Entry $entries -Command $command -Payload $payload
  $script:filterId = [string]$result.Filter
  $script:filterRule = [string]$result.Rule
  # WHY ask and never allow: an undecided call is not an authorisation, so the
  # runner allows only when a filter says so.
  if ([string]::IsNullOrEmpty($result.Decision)) {
    Complete-HarnessFilter -Harness $Harness -Decision 'ask' -Tool $toolName -Summary $summaryText -Reason 'nucleus-utils harness decide-call (no-filter): no enabled filter produced a verdict' -Rule no-filter
  }
  Complete-HarnessFilter -Harness $Harness -Decision $result.Decision -Tool $toolName -Summary $summaryText -Reason $result.Reason
}
catch {
  # Fail open to the harness's own prompt: a broken runner must not authorise a
  # call, and must not block one either.
  Write-HarnessBridgeWarning -CommandName 'decide-call' -Message $_.Exception.Message
  # WHY its own call: a crash is exactly the outcome a review looks for, so the
  # fail-open document is audited rather than only printed.
  Write-HarnessFilterAudit -Harness $Harness -Decision 'ask' -Rule 'runner-error'
  $document = Format-HarnessDecisionDocument -Decision 'ask' -Reason 'nucleus-utils harness decide-call (runner-error): the runner failed, so the harness prompts'
  Write-Output (ConvertTo-HarnessFilterDocument -Harness $Harness -Document $document)
}

exit 0
