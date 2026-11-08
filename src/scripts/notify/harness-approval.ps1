<#
.SYNOPSIS
  Requests an approval decision for a harness tool call from the enabled sources
  (Windows).

.DESCRIPTION
  Windows twin of harness-approval.sh. A harness hook (VS Code Copilot
  PreToolUse, Cursor beforeShellExecution, pi tool_call, opencode permission)
  calls this, then maps the printed decision onto its own response shape. With
  no -Plain the document is that harness's own vocabulary; with -Plain it is the
  decision word alone, which is how harness-filter consults the same sources for
  a call no filter decides.

  Sources are independent and race when more than one is enabled; the first
  answer wins and the other is dropped:
    prompt  asks in the console the hook runs under, over CONIN$. A hook started
            without a console answers `ask` instead of reading a denial into its
            own silence.
    hermes  publishes a request under <USER root>\state\harness-bridge and waits
            for `/harness approve <id>` or `/harness deny <id>` on a channel.

  A timeout of 0 waits until an answer arrives, so the harness's own hook
  timeout is the ceiling: the hook files declare 3600 s, which outlasts any human
  answer and still ends a session that nobody is watching.

  Deployed verbatim to <USER root>\bin and reached through the
  %USERPROFILE%\.local\bin\harness-approval.cmd shim, together with the sibling
  harness-bridge-common.ps1 it dot-sources for the shared helpers (see
  harness-notify.ps1 for the same reasoning).

  `ask` means "no source decided": the harness must fall back to its own local
  prompt.  Every path prints a decision and exits 0: a harness hook that fails is
  treated as a denial by some harnesses, which would turn a broker outage into a
  blocked session.

.PARAMETER Harness
  Harness name (pi, opencode, cursor, copilot).

.PARAMETER Tool
  Tool name the harness reported.

.PARAMETER Summary
  Human-readable description of the call.

.PARAMETER TimeoutSeconds
  Wait override applied to every enabled source; omitted means each source keeps
  its configured timeout. 0 waits indefinitely.

.PARAMETER Plain
  Print the decision word alone instead of the harness's document.

.EXAMPLE
  pwsh -NoProfile -File harness-approval.ps1 cursor Shell 'git push --force'

.EXAMPLE
  pwsh -NoProfile -File harness-approval.ps1 -Plain copilot runInTerminal 'rm -rf x'

.NOTES
  Exit codes: always 0.

  Config (~\.local\state\nucleus\config.json):
    harness-notify.enable                      boolean, default true; false
                                               answers `ask` at once
    harness-approval.sources                   list of sources, default
                                               ["prompt"]; an empty list answers
                                               `ask` at once
    harness-approval.timeout-seconds.<source>  integer seconds, default 0, which
                                               waits indefinitely
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
  [int]$TimeoutSeconds = -1,

  [switch]$Plain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# WHY $PSScriptRoot: Windows deploys a copy of this script outside the repository,
# so the shared helpers are resolved beside the copy, never by a repo-relative path.
. (Join-Path -Path $PSScriptRoot -ChildPath 'harness-bridge-common.ps1')

# WHY script scope: the audit line is written once, at the single exit every
# path funnels through, so the start time, the answering source, and the input
# fingerprint are collected here as the run produces them.
$script:auditStart = [datetime]::UtcNow
$script:auditDigest = ''
$script:decidedBy = ''
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
      sources           = @('prompt')
      'timeout-seconds' = @{ hermes = 0; prompt = 0 }
    }
    'harness-notify'   = @{ enable = $true }
  }
  if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return $config }
  $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($raw)) { return $config }

  # Malformed JSON throws: the caller answers `ask`, matching the POSIX twin.
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
    Renders a decision in the calling harness's own vocabulary.
  .DESCRIPTION
    `ask` is valid in every shape, so the neutral answer is always expressible.
  .PARAMETER Harness
    Calling harness name.
  .PARAMETER Decision
    allow, ask, or deny.
  .PARAMETER Plain
    Print the word alone, for a caller that renders its own document.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$Harness,

    [Parameter(Mandatory)]
    [ValidateSet('allow', 'ask', 'deny')]
    [string]$Decision,

    [switch]$Plain
  )

  if ($Plain) { return $Decision }

  switch ($Harness) {
    'cursor' {
      return (ConvertTo-Json -InputObject @{ permission = $Decision } -Compress -Depth 5)
    }
    'copilot' {
      return (ConvertTo-Json -InputObject @{
          hookSpecificOutput = @{
            hookEventName             = 'PreToolUse'
            permissionDecision        = $Decision
            permissionDecisionReason  = 'nucleus harness-approval'
          }
        } -Compress -Depth 5)
    }
    default { return $Decision }
  }
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

function Get-HarnessApprovalConsoleAnswer {
  <#
  .SYNOPSIS
    Maps one console byte to a decision.
  .DESCRIPTION
    The console is line-buffered, so a read completes after Enter and the first
    character carries the answer. y and a approve, n and d deny, and anything
    else is not an answer.
  .PARAMETER Byte
    First byte of the line the user typed.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [byte]$Byte
  )

  $key = [string][char]$Byte
  if ($key -in @('a', 'A', 'y', 'Y')) { return 'allow' }
  if ($key -in @('d', 'D', 'n', 'N')) { return 'deny' }
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
    Write-HarnessBridgeWarning -CommandName 'harness-approval' -Message 'could not sweep stale harness-bridge state'
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
    & (Join-Path -Path $PSScriptRoot -ChildPath 'harness-notify.ps1') $Harness approval `
      "$Tool`: $Summary (reply /harness approve $requestId)"
  }
  catch {
    Write-HarnessBridgeWarning -CommandName 'harness-approval' -Message 'approval notification failed: the request is still visible via /harness status'
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

  $console = $null
  $pending = $null
  $buffer = [byte[]]::new(1)
  if ($promptLive) {
    try { $console = Open-HarnessApprovalConsole }
    catch {
      Write-HarnessBridgeWarning -CommandName 'harness-approval' -Message 'no console for the prompt source: asking locally'
      $promptLive = $false
    }
  }
  if ($promptLive) {
    try {
      $writer = [System.IO.StreamWriter]::new($console.Out, [System.Text.UTF8Encoding]::new($false))
      $writer.Write("nucleus approval: ${Tool}: ${Summary}`r`n  run it? [y]es / [n]o / [a]lways / [d]on't: ")
      $writer.Flush()
      $pending = $console.In.ReadAsync($buffer, 0, 1)
    }
    catch {
      Write-HarnessBridgeWarning -CommandName 'harness-approval' -Message 'could not write to the console: asking locally'
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
          $decision = [string]$answer['decision']
          $answeredBy = 'hermes'
        }
      }
      catch {
        Write-HarnessBridgeWarning -CommandName 'harness-approval' -Message 'unreadable approval response: asking locally'
      }
      if (-not [string]::IsNullOrEmpty($decision)) { break }
    }

    if ($promptLive -and $now -ge $promptDeadline) { $promptLive = $false }
    if ($hermesLive -and $now -ge $hermesDeadline) { $hermesLive = $false }
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
        Write-HarnessBridgeWarning -CommandName 'harness-approval' -Message 'the console closed before an answer: asking locally'
        $promptLive = $false
        $pending = $null
      }
      if ($answered -and $bytesRead -le 0) {
        Write-HarnessBridgeWarning -CommandName 'harness-approval' -Message 'the console closed before an answer: asking locally'
        $promptLive = $false
        $pending = $null
      }
      elseif ($answered) {
        $decision = Get-HarnessApprovalConsoleAnswer -Byte $buffer[0]
        $pending = $null
        if (-not [string]::IsNullOrEmpty($decision)) {
          $answeredBy = 'prompt'
          break
        }
        # Any other key is not an answer: ask again rather than read it as one.
        try { $pending = $console.In.ReadAsync($buffer, 0, 1) }
        catch {
          Write-HarnessBridgeWarning -CommandName 'harness-approval' -Message 'the console closed before an answer: asking locally'
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
      Write-HarnessBridgeWarning -CommandName 'harness-approval' -Message 'could not write to the console'
    }
    $console.In.Dispose()
    $console.Out.Dispose()
  }

  if ($decision -in @('allow', 'deny')) { return @{ Decision = $decision; Source = $answeredBy } }
  # WHY keep the source: a source that answered with something unusable still
  # answered, and the audit line has to say which one it was.
  return @{ Decision = 'ask'; Source = $answeredBy }
}

function Complete-HarnessApproval {
  <#
  .SYNOPSIS
    Records the decision, prints it in the caller's vocabulary, and exits 0.
  .PARAMETER Harness
    Calling harness name.
  .PARAMETER Tool
    Tool name.
  .PARAMETER Summary
    One-line description of the call.
  .PARAMETER Decision
    allow, deny, or ask.
  .PARAMETER Plain
    Print the decision word alone.
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

    [switch]$Plain
  )

  $final = if ($Decision -in @('allow', 'deny')) { $Decision } else { 'ask' }
  # WHY the tool and the summary: the gate never sees the harness payload, so the
  # request text is the raw input it can vouch for.
  $summaryText = if ([string]::IsNullOrEmpty($Tool)) { $Summary } else { "${Tool}: ${Summary}" }
  try {
    Write-HarnessBridgeAuditEvent -Kind 'approval' -Harness $Harness -Decision $final `
      -Source $script:decidedBy -Summary $summaryText -Digest $script:auditDigest `
      -StartTime $script:auditStart -Id $script:requestId
  }
  catch {
    Write-HarnessBridgeWarning -CommandName 'harness-approval' -Message "could not write the harness audit log: $($_.Exception.Message)"
  }
  Write-Output (ConvertTo-HarnessApprovalDocument -Harness $Harness -Decision $final -Plain:$Plain)
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
    Write-HarnessBridgeWarning -CommandName 'harness-approval' -Message 'usage: harness-approval <harness> <tool> <summary> [timeout-seconds]'
    Write-Output 'ask'
    exit 0
  }

  $configPath = Get-HarnessBridgeConfigPath

  if ([string]::IsNullOrWhiteSpace($toolName)) {
    Write-HarnessBridgeWarning -CommandName 'harness-approval' -Message 'usage: harness-approval <harness> <tool> <summary> [timeout-seconds]'
    Complete-HarnessApproval -Harness $harnessName -Tool '' -Summary '' -Decision 'ask' -Plain:$Plain
  }
  if ($TimeoutSeconds -lt -1) {
    Write-HarnessBridgeWarning -CommandName 'harness-approval' -Message 'the timeout argument must be a whole number of seconds'
    Complete-HarnessApproval -Harness $harnessName -Tool $toolName -Summary $summaryText -Decision 'ask' -Plain:$Plain
  }

  try { $config = Get-HarnessBridgeApprovalConfig -ConfigPath $configPath }
  catch {
    Write-HarnessBridgeWarning -CommandName 'harness-approval' -Message 'could not parse nucleus config: asking locally'
    Complete-HarnessApproval -Harness $harnessName -Tool $toolName -Summary $summaryText -Decision 'ask' -Plain:$Plain
  }

  if (-not $config['harness-notify'].enable) {
    Complete-HarnessApproval -Harness $harnessName -Tool $toolName -Summary $summaryText -Decision 'ask' -Plain:$Plain
  }

  # The sources are the gate: none enabled keeps the hooks wired while every tool
  # call is answered `ask` at once and the harness keeps its own prompt.
  try { $sourceName = Resolve-HarnessApprovalSource -Config $config['harness-approval'] }
  catch {
    Write-HarnessBridgeWarning -CommandName 'harness-approval' -Message "$($_.Exception.Message): asking locally"
    Complete-HarnessApproval -Harness $harnessName -Tool $toolName -Summary $summaryText -Decision 'ask' -Plain:$Plain
  }
  try {
    $promptTimeout = Get-HarnessApprovalSourceTimeout -Config $config['harness-approval'] -Source 'prompt'
    $hermesTimeout = Get-HarnessApprovalSourceTimeout -Config $config['harness-approval'] -Source 'hermes'
  }
  catch {
    Write-HarnessBridgeWarning -CommandName 'harness-approval' -Message "$($_.Exception.Message): asking locally"
    Complete-HarnessApproval -Harness $harnessName -Tool $toolName -Summary $summaryText -Decision 'ask' -Plain:$Plain
  }
  if ($TimeoutSeconds -ge 0) {
    $promptTimeout = $TimeoutSeconds
    $hermesTimeout = $TimeoutSeconds
  }
  if (@($sourceName).Count -eq 0) {
    Complete-HarnessApproval -Harness $harnessName -Tool $toolName -Summary $summaryText -Decision 'ask' -Plain:$Plain
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
      Write-HarnessBridgeWarning -CommandName 'harness-approval' -Message "could not publish the approval request: asking locally ($($_.Exception.Message))"
      Complete-HarnessApproval -Harness $harnessName -Tool $toolName -Summary $summaryText -Decision 'ask' -Plain:$Plain
    }
    $requestPath = $request.RequestPath
    $responsePath = $request.ResponsePath
    $script:requestId = [string]$request.Id
  }

  $wait = Wait-HarnessApproval -Source $sourceName -PromptTimeout $promptTimeout `
    -HermesTimeout $hermesTimeout -Tool $toolName -Summary $summaryText -ResponsePath $responsePath
  $script:decidedBy = $wait.Source
  $decision = $wait.Decision

  # The request is consumed either way: an answered request would otherwise stay
  # in `/harness status`, and an unanswered one must not linger as pending.
  if (-not [string]::IsNullOrEmpty($requestPath)) {
    Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: already answered or timed out; a missing file is the expected steady state
    Remove-Item -LiteralPath $responsePath -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: absent unless answered; a missing file is the expected steady state
  }

  Complete-HarnessApproval -Harness $harnessName -Tool $toolName -Summary $summaryText -Decision $decision -Plain:$Plain
}
catch {
  # Fail open: an unreachable broker or an unwritable state directory must not
  # wedge the harness, and must not silently authorise anything either.
  Write-HarnessBridgeWarning -CommandName 'harness-approval' -Message $_.Exception.Message
  $fallbackHarness = if ([string]::IsNullOrWhiteSpace($harnessName)) { 'other' } else { $harnessName }
  # WHY its own try: this is the crash path a review looks for, so it is audited
  # rather than only printed, and logging here must not break the document either.
  try {
    Write-HarnessBridgeAuditEvent -Kind 'approval' -Harness $fallbackHarness -Decision 'ask' `
      -Source 'none' -Summary 'harness-approval (fail-open)' -Digest $script:auditDigest `
      -StartTime $script:auditStart
  }
  catch {
    Write-HarnessBridgeWarning -CommandName 'harness-approval' -Message "could not write the harness audit log: $($_.Exception.Message)"
  }
  Write-Output (ConvertTo-HarnessApprovalDocument -Harness $fallbackHarness -Decision 'ask' -Plain:$Plain)
}

exit 0
