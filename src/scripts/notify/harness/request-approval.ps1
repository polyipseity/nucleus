<#
.SYNOPSIS
  Requests an approval decision for a harness tool call from the enabled sources
  (Windows).

.DESCRIPTION
  Windows twin of request-approval.sh. A harness hook (VS Code Copilot
  PreToolUse, Cursor beforeShellExecution, pi tool_call, opencode permission)
  calls this and reads the one JSON decision document it prints. Harness
  adapters render that document in their own vocabulary; there is no plain-word
  mode and no per-harness shape.

  Sources are independent and race when more than one is enabled; the first
  answer wins and the other is dropped:
    prompt  asks in the console the hook runs under, over CONIN$. A hook started
            without a console answers `ask` instead of reading a denial into its
            own silence. The console is shared with the harness, so the answer is
            a line: only Enter decides, and a keystroke meant for the harness TUI
            is never read as one.
    hermes  publishes a request under <USER root>\state\harness-bridge and waits
            for `/harness approve <id>` or `/harness deny <id>` on a channel.

  A timeout of 0 waits until an answer arrives, so the harness's own hook
  timeout is the ceiling: the hook files declare 3600 s, which outlasts any human
  answer and still ends a session that nobody is watching.

  Invoked as `nucleus-utils harness request-approval ...` via scripts/utils.{sh,ps1}.
  Hooks resolve nucleus-utils through PATH (POSIX nucleus app, Windows nucleus-*
  shim deployed by Sync-NucleusAppShim.ps1). The sibling harness-bridge-common.ps1
  is dot-sourced for shared helpers.

  `ask` means "no source decided": the harness must fall back to its own local
  prompt. A resolver error or every source timing out is a typed deny that names
  the reason. Every path prints a document and exits 0: some harnesses treat a
  failed hook as a denial.

.PARAMETER Harness
  Harness name (pi, opencode, cursor, copilot).

.PARAMETER Tool
  Tool name the harness reported.

.PARAMETER Summary
  Human-readable description of the call.

.PARAMETER TimeoutSeconds
  Wait override applied to every enabled source; omitted means each source keeps
  its configured timeout. 0 waits indefinitely.

.EXAMPLE
  pwsh -NoProfile -File request-approval.ps1 cursor Shell 'git push --force'

.NOTES
  Exit codes: always 0.

  Config (~\.local\state\nucleus\config.json):
    harness-notify.enable                      boolean, default true; false
                                               answers `ask` at once
    harness-approval.sources                   list of sources, default
                                               ["prompt","hermes"]; an empty
                                               list answers `ask` at once
    harness-approval.timeout-seconds.<source>  integer seconds, default 300 for
                                               hermes and 600 for prompt
#>


[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$Harness,

  [Parameter(Position = 1)]
  [string]$Tool,

  [Parameter(Position = 2)]
  [string]$Summary,

  [Parameter(Position = 3)]
  [int]$TimeoutSeconds = -1
)

. (Join-Path $PSScriptRoot '..\..\lib\pwsh-guard.ps1')
Assert-NucleusPowerShell -Minimum '7.0'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# WHY $PSScriptRoot: Windows deploys a copy of this script outside the repository,
# so the shared helpers are resolved beside the copy, never by a repo-relative path.
. (Join-Path -Path $PSScriptRoot -ChildPath '../harness-bridge-common.ps1')

# WHY script scope: the audit line is written once, at the single exit every
# path funnels through, so the start time, the answering source, and the input
# fingerprint are collected here as the run produces them.
$script:auditStart = [datetime]::UtcNow
$script:auditDigest = ''
$script:requestId = ''

function Get-HarnessBridgeApprovalConfig {
  <#
  .SYNOPSIS
    Reads the master flag, the approval sources and the per-source timeouts over
    the defaults.
  .DESCRIPTION
    Keeps the config sections apart: both declare an enable flag, and flattening
    them into one hashtable would let the approval flag shadow the master flag.
    The timeout table is merged per source, because a user who sets one source's
    timeout must keep the other source's default.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)]
    [string]$ConfigPath
  )

  $config = @{
    'harness-approval' = @{
      sources           = @('prompt', 'hermes')
      'timeout-seconds' = @{ hermes = 300; prompt = 600 }
    }
    'harness-notify'   = @{ enable = $true }
  }
  if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return $config }
  $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($raw)) { return $config }

  # Malformed JSON throws: the caller emits a typed resolver-error deny,
  # matching the POSIX twin.
  $parsed = ConvertFrom-Json -InputObject $raw -AsHashtable
  if ($parsed -isnot [hashtable]) { return $config }
  foreach ($sectionName in @('harness-approval', 'harness-notify')) {
    if (-not $parsed.ContainsKey($sectionName)) { continue }
    $section = $parsed[$sectionName]
    if ($section -isnot [hashtable]) { continue }
    foreach ($key in $section.Keys) {
      if ($sectionName -eq 'harness-approval' -and $key -eq 'timeout-seconds' -and $section[$key] -is [hashtable]) {
        foreach ($sourceName in $section[$key].Keys) {
          $config[$sectionName]['timeout-seconds'][$sourceName] = $section[$key][$sourceName]
        }
        continue
      }
      $config[$sectionName][$key] = $section[$key]
    }
  }
  return $config
}

function ConvertTo-HarnessApprovalDocument {
  <#
  .SYNOPSIS
    Renders the one typed decision document the adapters consume.
  .DESCRIPTION
    The field order and the timeout values are the wire contract. An empty
    reason would leave the adapter with nothing to show the operator, so it is
    rejected here rather than printed.
  .PARAMETER Decision
    allow, deny, or ask.
  .PARAMETER Reason
    Why the resolver answered this way.
  .PARAMETER Source
    Source that decided, or a resolver status when none did.
  .PARAMETER TimedOutSources
    Sources that gave up waiting.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [ValidateSet('allow', 'deny', 'ask')]
    [string]$Decision,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Reason,

    [Parameter(Mandatory)]
    [ValidateSet('prompt', 'hermes', 'all-timeouts', 'resolver-error', 'none')]
    [string]$Source,

    [string[]]$TimedOutSources = @()
  )

  if ([string]::IsNullOrWhiteSpace($Reason)) { throw 'a decision document needs a reason' }
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

function Resolve-HarnessApprovalSource {
  <#
  .SYNOPSIS
    Reads the enabled source names from the approval config.
  .DESCRIPTION
    The list is the gate: no source answers `ask` at once. An unknown name is a
    configuration mistake, and answering `ask` keeps the harness's own prompt
    rather than silently waiting on a source that does not exist.
  .PARAMETER Config
    Merged harness-approval section.
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory)]
    [hashtable]$Config
  )

  if (-not $Config.ContainsKey('sources')) { return }
  $raw = $Config['sources']
  if ($raw -is [string]) {
    throw "harness-approval.sources must be a list of source names, not the string '$raw'"
  }
  if ($null -eq $raw) { return }

  [string[]]$names = @()
  foreach ($item in @($raw)) {
    $name = [string]$item
    if ($name -notin @('hermes', 'prompt')) {
      throw "unknown harness-approval source '$name'"
    }
    $names += $name
  }
  return $names
}

function Get-HarnessApprovalSourceTimeout {
  <#
  .SYNOPSIS
    Reads one source's timeout in seconds, 0 meaning never.
  .PARAMETER Config
    Merged harness-approval section.
  .PARAMETER Source
    Source name.
  #>
  [CmdletBinding()]
  [OutputType([int])]
  param(
    [Parameter(Mandatory)]
    [hashtable]$Config,

    [Parameter(Mandatory)]
    [string]$Source
  )

  if (-not $Config.ContainsKey('timeout-seconds')) { return 0 }
  $table = $Config['timeout-seconds']
  if ($table -isnot [hashtable]) { throw 'harness-approval.timeout-seconds must be a table of source names' }
  if (-not $table.ContainsKey($Source)) { return 0 }

  $value = $table[$Source]
  $seconds = 0
  if (-not [int]::TryParse([string]$value, [ref]$seconds) -or $seconds -lt 0) {
    throw "harness-approval.timeout-seconds.$Source is not a whole number of seconds"
  }
  return $seconds
}

function Open-HarnessApprovalConsole {
  <#
  .SYNOPSIS
    Opens the console of the process the hook runs under, for the prompt source.
  .DESCRIPTION
    A harness hook has its stdin and stdout wired to the payload and the
    decision, so the console is reached as a device rather than through the
    standard streams: CONIN$ and CONOUT$ are the Windows spelling of /dev/tty.
    A process started without a console (a service, a pipe-only host) throws
    here, and the caller answers `ask`.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param()

  $consoleIn = $null
  $consoleOut = $null
  try {
    $consoleIn = [System.IO.File]::Open('CONIN$', [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $consoleOut = [System.IO.File]::Open('CONOUT$', [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
  }
  catch {
    if ($null -ne $consoleIn) { $consoleIn.Dispose() }
    throw 'no console for the prompt source'
  }
  return @{ In = $consoleIn; Out = $consoleOut }
}

function Get-HarnessApprovalConsoleLineAnswer {
  <#
  .SYNOPSIS
    Maps one typed line to a decision.
  .DESCRIPTION
    The console is shared with the harness, so the answer is a line rather than a
    keystroke: only Enter completes it, and a key aimed at the harness TUI is
    never read as one. The prompt reads `[y]es`, so the spelled-out word answers
    too, and the comparison ignores case and spaces. An empty line or any other
    word is not an answer.
  .PARAMETER Line
    Text the console delivered before the first line break.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Line
  )

  $word = ($Line -replace '\s', '').ToLowerInvariant()
  if ($word -in @('a', 'allow', 'y', 'yes')) { return 'allow' }
  if ($word -in @('d', "don't", 'dont', 'n', 'no')) { return 'deny' }
  return ''
}

function Request-HarnessApproval {
  <#
  .SYNOPSIS
    Publishes a pending tool call for the Hermes source.
  .DESCRIPTION
    An empty summary is valid: the runner passes whatever text the hook payload
    carried, and a request that cannot describe itself must still be published
    rather than fail the gate open.
  .DESCRIPTION
    Writes the request under a temporary name and renames it, because the bridge
    plugin lists requests with a glob: a request must appear complete or not at
    all. Requests and responses older than four times the longest finite wait,
    or than the hook ceiling when every source waits indefinitely, are swept
    first, so a harness killed mid-poll does not leave `/harness status` dirty.
  .PARAMETER Harness
    Calling harness name.
  .PARAMETER Tool
    Tool name.
  .PARAMETER Summary
    One-line description.
  .PARAMETER WindowSeconds
    Age past which an abandoned request or response is swept.
  .PARAMETER UserRoot
    Absolute nucleus USER root.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)]
    [string]$Harness,

    [Parameter(Mandatory)]
    [string]$Tool,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Summary,

    [Parameter(Mandatory)]
    [int]$WindowSeconds,

    [Parameter(Mandatory)]
    [string]$UserRoot
  )

  $stateDir = Join-Path -Path $UserRoot -ChildPath 'state/harness-bridge'
  $requestsDir = Join-Path -Path $stateDir -ChildPath 'requests'
  $responsesDir = Join-Path -Path $stateDir -ChildPath 'responses'
  $null = New-Item -ItemType Directory -Path $requestsDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded
  $null = New-Item -ItemType Directory -Path $responsesDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded

  $staleCutoff = [DateTime]::UtcNow.AddSeconds(-1 * $WindowSeconds)
  try {
    foreach ($dir in @($requestsDir, $responsesDir)) {
      Get-ChildItem -LiteralPath $dir -File |
        Where-Object { ($_.Name -like '*.json' -or $_.Name -like '*.tmp') -and $_.LastWriteTimeUtc -lt $staleCutoff } |
        Remove-Item -Force
    }
  }
  catch {
    Write-HarnessBridgeWarning -CommandName 'request-approval' -Message 'could not sweep stale harness-bridge state'
  }

  $requestId = ([guid]::NewGuid().ToString('N')).Substring(0, 8)
  $requestPath = Join-Path -Path $requestsDir -ChildPath "$requestId.json"
  $responsePath = Join-Path -Path $responsesDir -ChildPath "$requestId.json"

  $requestJson = ConvertTo-Json -InputObject @{
    id         = $requestId
    harness    = $Harness
    tool       = $Tool
    summary    = $Summary
    created_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  } -Compress -Depth 5
  # WHY a temporary name beside the destination: the bridge plugin lists
  # requests with a glob, so a request has to appear complete or not at all.
  $requestTempPath = "$requestPath.tmp"
  try {
    [System.IO.File]::WriteAllText($requestTempPath, $requestJson, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::Move($requestTempPath, $requestPath, $true)
  }
  catch {
    Remove-Item -LiteralPath $requestTempPath -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: the failure being reported is the publish itself; the temporary file may not exist
    throw
  }

  # Best-effort: the request file is the source of truth, so a failed
  # notification only means the user looks at /harness status instead of being
  # pinged.
  try {
    & (Join-Path -Path $PSScriptRoot -ChildPath 'send-notification.ps1') $Harness approval `
      "$Tool`: $Summary (reply /harness approve $requestId)"
  }
  catch {
    Write-HarnessBridgeWarning -CommandName 'request-approval' -Message 'approval notification failed: the request is still visible via /harness status'
  }

  return @{ Id = $requestId; RequestPath = $requestPath; ResponsePath = $responsePath }
}

function Wait-HarnessApproval {
  <#
  .SYNOPSIS
    Races the enabled sources and returns the first answer and its source.
  .DESCRIPTION
    One loop, so neither source needs a process to kill: the response file is
    checked every pass, and a live prompt keeps a pending console read whose
    one-second wait doubles as the poll interval. Leaving the loop drops the
    other source.
  .PARAMETER Source
    Enabled source names.
  .PARAMETER PromptTimeout
    Seconds the prompt waits, 0 meaning never.
  .PARAMETER HermesTimeout
    Seconds the request waits, 0 meaning never.
  .PARAMETER Tool
    Tool name, for the prompt text.
  .PARAMETER Summary
    One-line description, for the prompt text.
  .PARAMETER ResponsePath
    Response file of the published request, or an empty string when the Hermes
    source is not enabled.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [string[]]$Source,

    [Parameter(Mandatory)]
    [int]$PromptTimeout,

    [Parameter(Mandatory)]
    [int]$HermesTimeout,

    [Parameter(Mandatory)]
    [string]$Tool,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Summary,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$ResponsePath
  )

  $promptLive = $Source -contains 'prompt'
  $hermesLive = $Source -contains 'hermes' -and -not [string]::IsNullOrEmpty($ResponsePath)
  $timedOut = [System.Collections.Generic.List[string]]::new()
  $noAnswerReason = 'no approval source answered'
  $reason = ''

  $console = $null
  $pending = $null
  # WHY a line-sized buffer: the console delivers the whole line when line input
  # is on, and one keystroke per read when a harness turned it off, so one read
  # can carry either and the accumulator below decides which arrived.
  $buffer = [byte[]]::new(256)
  $typedLine = [System.Text.StringBuilder]::new()
  if ($promptLive) {
    try { $console = Open-HarnessApprovalConsole }
    catch {
      Write-HarnessBridgeWarning -CommandName 'request-approval' -Message 'no console for the prompt source: answering ask'
      $noAnswerReason = 'no terminal for the prompt source'
      $promptLive = $false
    }
  }
  if ($promptLive) {
    try {
      $writer = [System.IO.StreamWriter]::new($console.Out, [System.Text.UTF8Encoding]::new($false))
      $writer.Write("nucleus approval: ${Tool}: ${Summary}`r`n  run it? [y]es / [n]o / [a]llow once / [d]on't: ")
      $writer.Flush()
      $pending = $console.In.ReadAsync($buffer, 0, $buffer.Length)
    }
    catch {
      Write-HarnessBridgeWarning -CommandName 'request-approval' -Message 'could not write to the console: answering ask'
      $noAnswerReason = 'could not write to the terminal'
      $promptLive = $false
      $pending = $null
    }
  }

  $start = [DateTime]::UtcNow
  $promptDeadline = if ($PromptTimeout -gt 0) { $start.AddSeconds($PromptTimeout) } else { [DateTime]::MaxValue }
  $hermesDeadline = if ($HermesTimeout -gt 0) { $start.AddSeconds($HermesTimeout) } else { [DateTime]::MaxValue }
  $decision = ''
  $answeredBy = ''

  while ([string]::IsNullOrEmpty($decision)) {
    $now = [DateTime]::UtcNow

    if ($hermesLive -and (Test-Path -LiteralPath $ResponsePath -PathType Leaf)) {
      $hermesLive = $false
      try {
        $answer = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $ResponsePath -Raw -Encoding UTF8) -AsHashtable
        if ($answer -is [hashtable] -and $answer.ContainsKey('decision')) {
          $candidate = [string]$answer['decision']
          if ($candidate -in @('allow', 'deny')) {
            $decision = $candidate
            $answeredBy = 'hermes'
            $reason = if ($answer.ContainsKey('reason') -and $answer['reason'] -is [string] -and
              -not [string]::IsNullOrWhiteSpace([string]$answer['reason'])) {
              [string]$answer['reason']
            }
            else { 'hermes decision' }
          }
        }
      }
      catch {
        Write-HarnessBridgeWarning -CommandName 'request-approval' -Message 'unreadable approval response'
      }
      if ([string]::IsNullOrEmpty($decision)) {
        Write-HarnessBridgeWarning -CommandName 'request-approval' -Message 'malformed hermes approval response: answering deny'
        $decision = 'deny'
        $answeredBy = 'resolver-error'
        $reason = 'malformed hermes approval response'
      }
      break
    }

    if ($promptLive -and $now -ge $promptDeadline) {
      if ($timedOut -notcontains 'prompt') { $timedOut.Add('prompt') }
      $promptLive = $false
    }
    if ($hermesLive -and $now -ge $hermesDeadline) {
      if ($timedOut -notcontains 'hermes') { $timedOut.Add('hermes') }
      $hermesLive = $false
    }
    if (-not $promptLive -and -not $hermesLive) { break }

    if ($promptLive -and $null -ne $pending) {
      $answered = $false
      $bytesRead = 0
      try {
        $answered = $pending.Wait(1000)
        # WHY the byte count: a console that went away completes the read with
        # nothing, and treating that as a rejected key would re-read forever. The
        # POSIX twin reads the same signal from `read`'s status.
        if ($answered) { $bytesRead = $pending.Result }
      }
      catch {
        # A closed console faults the pending read, which is the same situation as
        # a console that was never there.
        Write-HarnessBridgeWarning -CommandName 'request-approval' -Message 'the console closed before an answer: answering ask'
        $noAnswerReason = 'the terminal closed before an answer'
        $promptLive = $false
        $pending = $null
      }
      if ($answered -and $bytesRead -le 0) {
        Write-HarnessBridgeWarning -CommandName 'request-approval' -Message 'the console closed before an answer: answering ask'
        $noAnswerReason = 'the terminal closed before an answer'
        $promptLive = $false
        $pending = $null
      }
      elseif ($answered) {
        # WHY a stateless decode per read: a multi-byte character split across two
        # reads decodes to U+FFFD, and every accepted word is ASCII, so the worst
        # case is an unknown word and a re-prompt. A stateful decoder would buy
        # nothing the vocabulary can use.
        $typedLine.Append([System.Text.Encoding]::UTF8.GetString($buffer, 0, $bytesRead)) > $null
        $typed = $typedLine.ToString()
        $pending = $null
        $breakAt = $typed.IndexOfAny([char[]]@("`r", "`n"))
        if ($breakAt -ge 0) {
          # WHY the first control character rather than the break: a raw-mode Enter
          # is a bare CR and a stray ESC is another control byte, and the POSIX twin
          # cuts there, so `yes` followed by ESC and Enter decides on both hosts
          # instead of re-prompting on one.
          $cutAt = [regex]::Match($typed, '[\x00-\x1F\x7F]').Index
          $decision = Get-HarnessApprovalConsoleLineAnswer -Line $typed.Substring(0, $cutAt)
          $typedLine.Clear() > $null
          if (-not [string]::IsNullOrEmpty($decision)) {
            $answeredBy = 'prompt'
            $reason = if ($decision -eq 'allow') { 'prompt allowed' } else { 'prompt denied' }
            break
          }
        }
        # A partial line, an empty line, and an unknown word are not answers: read
        # again rather than decide on either.
        try { $pending = $console.In.ReadAsync($buffer, 0, $buffer.Length) }
        catch {
          Write-HarnessBridgeWarning -CommandName 'request-approval' -Message 'the console closed before an answer: answering ask'
          $noAnswerReason = 'the terminal closed before an answer'
          $promptLive = $false
          $pending = $null
        }
      }
    }
    elseif ($promptLive) {
      Start-Sleep -Milliseconds 200
    }
    else {
      Start-Sleep -Seconds 1
    }
  }

  if ($null -ne $console) {
    try {
      $closer = [System.IO.StreamWriter]::new($console.Out, [System.Text.UTF8Encoding]::new($false))
      $closer.Write("`r`n")
      $closer.Flush()
    }
    catch {
      Write-HarnessBridgeWarning -CommandName 'request-approval' -Message 'could not write to the console'
    }
    $console.In.Dispose()
    $console.Out.Dispose()
  }

  if (-not [string]::IsNullOrEmpty($decision)) {
    return @{
      Decision = $decision
      Source = $answeredBy
      Reason = $reason
      TimedOutSources = $timedOut.ToArray()
    }
  }
  if ($timedOut -contains 'hermes' -and $timedOut -contains 'prompt') {
    return @{
      Decision = 'deny'
      Source = 'all-timeouts'
      Reason = 'all approval sources timed out (hermes 300s, prompt 600s)'
      TimedOutSources = $timedOut.ToArray()
    }
  }
  return @{ Decision = 'ask'; Source = 'none'; Reason = $noAnswerReason; TimedOutSources = $timedOut.ToArray() }
}

function Complete-HarnessApproval {
  <#
  .SYNOPSIS
    Records the decision, prints its typed document, and exits 0.
  .PARAMETER Harness
    Calling harness name.
  .PARAMETER Tool
    Tool name.
  .PARAMETER Summary
    One-line description of the call.
  .PARAMETER Decision
    allow, deny, or ask.
  .PARAMETER Reason
    Why the resolver answered this way.
  .PARAMETER Source
    Source that decided, or a resolver status when none did.
  .PARAMETER TimedOutSources
    Sources that gave up waiting.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Harness,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Tool,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Summary,

    [Parameter(Mandatory)]
    [string]$Decision,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Reason,

    [Parameter(Mandatory)]
    [ValidateSet('prompt', 'hermes', 'all-timeouts', 'resolver-error', 'none')]
    [string]$Source,

    [string[]]$TimedOutSources = @()
  )

  $final = if ($Decision -in @('allow', 'deny')) { $Decision } else { 'ask' }
  # WHY the tool and the summary: the gate never sees the harness payload, so the
  # request text is the raw input it can vouch for.
  $summaryText = if ([string]::IsNullOrEmpty($Tool)) { $Summary } else { "${Tool}: ${Summary}" }
  try {
    Write-HarnessBridgeAuditEvent -Kind 'approval' -Harness $Harness -Decision $final `
      -Source $Source -Summary $summaryText -Digest $script:auditDigest `
      -StartTime $script:auditStart -Id $script:requestId
  }
  catch {
    Write-HarnessBridgeWarning -CommandName 'request-approval' -Message "could not write the harness audit log: $($_.Exception.Message)"
  }
  Write-Output (ConvertTo-HarnessApprovalDocument -Decision $final -Reason $Reason -Source $Source -TimedOutSources $TimedOutSources)
  exit 0
}

$harnessName = ''
$toolName = ''
$summaryText = ''

try {
  $harnessName = $Harness
  $toolName = $Tool
  $summaryText = $Summary
  $script:auditDigest = Get-HarnessBridgeDigest -Text "$toolName`t$summaryText"

  if ([string]::IsNullOrWhiteSpace($harnessName)) {
    Write-HarnessBridgeWarning -CommandName 'request-approval' -Message 'usage: nucleus-utils harness request-approval <harness> <tool> <summary> [timeout-seconds]'
    Complete-HarnessApproval -Harness 'other' -Tool '' -Summary '' -Decision 'deny' `
      -Reason 'harness-approval requires a harness name' -Source 'resolver-error'
  }

  $configPath = Get-HarnessBridgeConfigPath

  if ([string]::IsNullOrWhiteSpace($toolName)) {
    Write-HarnessBridgeWarning -CommandName 'request-approval' -Message 'usage: nucleus-utils harness request-approval <harness> <tool> <summary> [timeout-seconds]'
    Complete-HarnessApproval -Harness $harnessName -Tool '' -Summary '' -Decision 'deny' `
      -Reason 'harness-approval requires a tool name' -Source 'resolver-error'
  }
  if ($TimeoutSeconds -lt -1) {
    Write-HarnessBridgeWarning -CommandName 'request-approval' -Message 'the timeout argument must be a whole number of seconds'
    Complete-HarnessApproval -Harness $harnessName -Tool $toolName -Summary $summaryText -Decision 'deny' `
      -Reason 'the timeout argument must be a whole number of seconds' -Source 'resolver-error'
  }

  try { $config = Get-HarnessBridgeApprovalConfig -ConfigPath $configPath }
  catch {
    Write-HarnessBridgeWarning -CommandName 'request-approval' -Message 'could not parse nucleus config'
    Complete-HarnessApproval -Harness $harnessName -Tool $toolName -Summary $summaryText -Decision 'deny' `
      -Reason 'could not parse nucleus config' -Source 'resolver-error'
  }

  if (-not $config['harness-notify'].enable) {
    Complete-HarnessApproval -Harness $harnessName -Tool $toolName -Summary $summaryText -Decision 'ask' `
      -Reason 'harness notifications are disabled' -Source 'none'
  }

  # The sources are the gate: none enabled keeps the hooks wired while every tool
  # call is answered `ask` at once and the harness keeps its own prompt.
  try { $sourceName = Resolve-HarnessApprovalSource -Config $config['harness-approval'] }
  catch {
    Write-HarnessBridgeWarning -CommandName 'request-approval' -Message $($_.Exception.Message)
    Complete-HarnessApproval -Harness $harnessName -Tool $toolName -Summary $summaryText -Decision 'deny' `
      -Reason $($_.Exception.Message) -Source 'resolver-error'
  }
  try {
    $promptTimeout = Get-HarnessApprovalSourceTimeout -Config $config['harness-approval'] -Source 'prompt'
    $hermesTimeout = Get-HarnessApprovalSourceTimeout -Config $config['harness-approval'] -Source 'hermes'
  }
  catch {
    Write-HarnessBridgeWarning -CommandName 'request-approval' -Message $($_.Exception.Message)
    Complete-HarnessApproval -Harness $harnessName -Tool $toolName -Summary $summaryText -Decision 'deny' `
      -Reason $($_.Exception.Message) -Source 'resolver-error'
  }
  if ($TimeoutSeconds -ge 0) {
    $promptTimeout = $TimeoutSeconds
    $hermesTimeout = $TimeoutSeconds
  }
  if (@($sourceName).Count -eq 0) {
    Complete-HarnessApproval -Harness $harnessName -Tool $toolName -Summary $summaryText -Decision 'ask' `
      -Reason 'no approval sources enabled' -Source 'none'
  }

  # A zero wait would sweep the very request this run is waiting on, so the
  # window follows the longest finite wait, or the hook ceiling when every
  # source waits indefinitely.
  $windowSeconds = 3600
  $finiteWindow = [Math]::Max($promptTimeout, $hermesTimeout)
  if ($finiteWindow -gt 0) { $windowSeconds = 4 * $finiteWindow }

  $responsePath = ''
  $requestPath = ''
  if ($sourceName -contains 'hermes') {
    try {
      $request = Request-HarnessApproval -Harness $harnessName -Tool $toolName -Summary $summaryText `
        -WindowSeconds $windowSeconds -UserRoot (Get-HarnessBridgeUserRoot)
    }
    catch {
      Write-HarnessBridgeWarning -CommandName 'request-approval' -Message "could not publish the approval request: $($_.Exception.Message)"
      Complete-HarnessApproval -Harness $harnessName -Tool $toolName -Summary $summaryText -Decision 'deny' `
        -Reason 'could not publish the approval request' -Source 'resolver-error'
    }
    $requestPath = $request.RequestPath
    $responsePath = $request.ResponsePath
    $script:requestId = [string]$request.Id
  }

  $wait = Wait-HarnessApproval -Source $sourceName -PromptTimeout $promptTimeout `
    -HermesTimeout $hermesTimeout -Tool $toolName -Summary $summaryText -ResponsePath $responsePath
  $decision = $wait.Decision

  # The request is consumed either way: an answered request would otherwise stay
  # in `/harness status`, and an unanswered one must not linger as pending.
  if (-not [string]::IsNullOrEmpty($requestPath)) {
    Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: already answered or timed out; a missing file is the expected steady state
    Remove-Item -LiteralPath $responsePath -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: absent unless answered; a missing file is the expected steady state
  }

  Complete-HarnessApproval -Harness $harnessName -Tool $toolName -Summary $summaryText `
    -Decision $decision -Reason $wait.Reason -Source $wait.Source -TimedOutSources $wait.TimedOutSources
}
catch {
  # An unexpected resolver failure is a typed deny: no source can be trusted to
  # have decided, and an accidental allow is worse than a blocked call.
  Write-HarnessBridgeWarning -CommandName 'request-approval' -Message $_.Exception.Message
  $fallbackHarness = if ([string]::IsNullOrWhiteSpace($harnessName)) { 'other' } else { $harnessName }
  # WHY its own try: this is the crash path a review looks for, so it is audited
  # rather than only printed, and logging here must not break the document either.
  try {
    Write-HarnessBridgeAuditEvent -Kind 'approval' -Harness $fallbackHarness -Decision 'deny' `
      -Source 'resolver-error' -Summary 'harness-approval (resolver-error)' -Digest $script:auditDigest `
      -StartTime $script:auditStart
  }
  catch {
    Write-HarnessBridgeWarning -CommandName 'request-approval' -Message "could not write the harness audit log: $($_.Exception.Message)"
  }
  Write-Output (ConvertTo-HarnessApprovalDocument -Decision 'deny' -Reason 'approval resolver failed' -Source 'resolver-error')
}

exit 0
