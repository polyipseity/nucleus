<#
.SYNOPSIS
  Requests a remote approval decision for a harness tool call (Windows).

.DESCRIPTION
  Windows twin of harness-approval.sh.  A blocking harness hook (Cursor
  beforeShellExecution, VS Code Copilot PreToolUse, pi tool_call, opencode
  permission) calls this, then maps the printed decision onto its own response
  shape.  The request appears on every configured Hermes channel and is answered
  with `/harness approve <id>` or `/harness deny <id>`; `/harness status` lists
  what is still outstanding.

  This file is deployed verbatim to <USER root>\bin and reached through the
  %USERPROFILE%\.local\bin\harness-approval.cmd shim, so it is deliberately
  self-contained (see harness-notify.ps1 for the same reasoning).

  `ask` means "no remote decision" — the harness must fall back to its own local
  prompt.  Every path prints a decision and exits 0: a harness hook that fails is
  treated as a denial by some harnesses, which would turn a broker outage into a
  blocked session.

.PARAMETER Harness
  Harness name (pi, opencode, cursor, copilot), or the literal `hook` to select
  hook mode.

.PARAMETER Tool
  Tool name, or — in hook mode — the harness name.

.PARAMETER Summary
  Human-readable description of the call.  Optional in hook mode, where the
  description is extracted from the hook payload on stdin.

.PARAMETER TimeoutSeconds
  Optional wait override; the configured harness-approval.timeout-seconds is used
  when omitted or zero.

.EXAMPLE
  pwsh -NoProfile -File harness-approval.ps1 cursor Shell 'git push --force'

.EXAMPLE
  '{"command":"git push --force"}' | pwsh -NoProfile -File harness-approval.ps1 hook cursor

.NOTES
  Exit codes: always 0.

  Config (~\.local\state\nucleus\config.json):
    harness-notify.enable             boolean, default true; false answers `ask`
    harness-approval.enable           boolean, default false; false answers `ask`
                                      at once, so the harness prompts locally
    harness-approval.timeout-seconds  integer, default 120
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
  [int]$TimeoutSeconds
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-HarnessBridgeWarning {
  <#
  .SYNOPSIS
    Writes one F1 warning line to stderr without importing the shared module.
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
    Mirrors Get-NucleusUserRoot in ManagedPaths.ps1, inlined because this script
    is deployed outside the repository.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    throw 'harness-approval: %LOCALAPPDATA% is unset; the nucleus USER root is undefined'
  }
  return (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'nucleus')
}

function Get-HarnessBridgeConfigPath {
  <#
  .SYNOPSIS
    Resolves the nucleus runtime config path.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  return (Join-Path -Path $HOME -ChildPath '.local/state/nucleus/config.json')
}

function Get-HarnessBridgeApprovalConfig {
  <#
  .SYNOPSIS
    Reads the master flag, the approval gate and the timeout over the defaults.
  .DESCRIPTION
    Keeps the config sections apart: both sections declare an enable flag, and
    flattening them into one hashtable would let the approval flag shadow the
    master flag.
  .PARAMETER ConfigPath
    Absolute path to the nucleus runtime config file.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)]
    [string]$ConfigPath
  )

  $config = @{
    'harness-approval' = @{ enable = $false; 'timeout-seconds' = 120 }
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
    foreach ($key in $section.Keys) { $config[$sectionName][$key] = $section[$key] }
  }
  return $config
}

function ConvertTo-HarnessApprovalDocument {
  <#
  .SYNOPSIS
    Renders a decision in the calling harness's own vocabulary.
  .DESCRIPTION
    `ask` is a valid value in every shape, so the neutral answer is always
    expressible.
  .PARAMETER Harness
    Calling harness name.
  .PARAMETER Decision
    allow, deny, or ask.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$Harness,

    [Parameter(Mandatory)]
    [ValidateSet('allow', 'ask', 'deny')]
    [string]$Decision
  )

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

function Read-HarnessBridgeHookPayload {
  <#
  .SYNOPSIS
    Extracts the tool name and one-line action description from a hook payload.
  .DESCRIPTION
    The wired hook payloads (Cursor beforeShellExecution, Copilot PreToolUse) are
    JSON objects, but a harness may also hand over plain text, so both shapes are
    answered: JSON yields tool_name/tool_input when present, anything else is
    carried through as the description.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param()

  $result = @{ Tool = 'hook'; Summary = '' }
  if (-not [Console]::IsInputRedirected) { return $result }

  $payload = [Console]::In.ReadToEnd()
  if ([string]::IsNullOrWhiteSpace($payload)) { return $result }

  if (-not $payload.TrimStart().StartsWith('{')) {
    $result.Summary = $payload
  }
  else {
    $parsed = $null
    try { $parsed = ConvertFrom-Json -InputObject $payload -AsHashtable }
    catch { $result.Summary = $payload }

    if ($null -ne $parsed -and $parsed -is [hashtable]) {
      foreach ($field in @('tool_name', 'tool', 'hook_event_name')) {
        if ($parsed.ContainsKey($field) -and -not [string]::IsNullOrWhiteSpace([string]$parsed[$field])) {
          $result.Tool = [string]$parsed[$field]
          break
        }
      }

      $description = $null
      foreach ($field in @('tool_input', 'command', 'arguments')) {
        if ($parsed.ContainsKey($field) -and $null -ne $parsed[$field]) {
          $description = $parsed[$field]
          break
        }
      }
      if ($null -eq $description) { $description = $parsed }

      $result.Summary = if ($description -is [string]) { $description }
      else { ConvertTo-Json -InputObject $description -Compress -Depth 10 }
    }
  }

  # A hook payload is multi-line JSON; the request description is one line.
  $result.Summary = ($result.Summary -replace '\s+', ' ').Trim()
  if ($result.Summary.Length -gt 200) { $result.Summary = $result.Summary.Substring(0, 200) }
  return $result
}

function Request-HarnessApproval {
  <#
  .SYNOPSIS
    Announces a pending tool call and waits for a remote decision.
  .PARAMETER Harness
    Harness that asked for the decision.
  .PARAMETER Tool
    Tool name.
  .PARAMETER Summary
    One-line description of the call.
  .PARAMETER TimeoutSeconds
    How long to wait for an answer.
  .PARAMETER UserRoot
    Absolute path to the nucleus USER root.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$Harness,

    [Parameter(Mandatory)]
    [string]$Tool,

    [Parameter(Mandatory)]
    [string]$Summary,

    [Parameter(Mandatory)]
    [int]$TimeoutSeconds,

    [Parameter(Mandatory)]
    [string]$UserRoot
  )

  $stateDir = Join-Path -Path $UserRoot -ChildPath 'state/harness-bridge'
  $requestsDir = Join-Path -Path $stateDir -ChildPath 'requests'
  $responsesDir = Join-Path -Path $stateDir -ChildPath 'responses'
  $null = New-Item -ItemType Directory -Path $requestsDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded
  $null = New-Item -ItemType Directory -Path $responsesDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded

  # A harness killed mid-poll leaves its request behind, and an interrupted
  # publish leaves a `.tmp` companion; neither can ever be answered and both
  # would otherwise stay in `/harness status` forever.
  $staleCutoff = [DateTime]::UtcNow.AddSeconds(-4 * $TimeoutSeconds)
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
    Write-HarnessBridgeWarning -CommandName 'harness-approval' -Message 'approval notification failed — the request is still visible via /harness status'
  }

  $decision = ''
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    if (Test-Path -LiteralPath $responsePath -PathType Leaf) {
      try {
        $answer = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $responsePath -Raw -Encoding UTF8) -AsHashtable
        if ($answer -is [hashtable] -and $answer.ContainsKey('decision')) { $decision = [string]$answer['decision'] }
      }
      catch {
        Write-HarnessBridgeWarning -CommandName 'harness-approval' -Message "unreadable response '$requestId'"
      }
      break
    }
    Start-Sleep -Seconds 2
  }

  # The request is consumed either way: an answered request would otherwise stay
  # in `/harness status`, and an unanswered one must not linger as pending.
  Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: already answered or timed out; a missing file is the expected steady state
  Remove-Item -LiteralPath $responsePath -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: absent unless answered; a missing file is the expected steady state

  if ($decision -in @('allow', 'deny')) { return $decision }
  return 'ask'
}

function Write-HarnessBridgeAuditEntry {
  <#
  .SYNOPSIS
    Appends one decision to the harness-bridge audit log.
  .DESCRIPTION
    Hooks run invisibly, so what was asked and how it was answered has to be
    recoverable.  Best-effort: an unwritable log must not change the decision.
  .PARAMETER LogDir
    Absolute path to the nucleus log directory.
  .PARAMETER Harness
    Harness that asked.
  .PARAMETER Tool
    Tool name.
  .PARAMETER Decision
    Final decision.
  .PARAMETER Summary
    One-line description of the call.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$LogDir,

    [Parameter(Mandatory)]
    [string]$Harness,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Tool,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Decision,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Summary
  )

  try {
    $null = New-Item -ItemType Directory -Path $LogDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded
    $line = @(
      [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
      $Harness
      $Tool
      $Decision
      $Summary
    ) -join "`t"
    Add-Content -LiteralPath (Join-Path -Path $LogDir -ChildPath 'harness-bridge.log') -Value $line -Encoding utf8
  }
  catch {
    Write-HarnessBridgeWarning -CommandName 'harness-approval' -Message 'could not write the harness-bridge audit log'
  }
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
  .PARAMETER LogDir
    Absolute path to the nucleus log directory.
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
    [string]$LogDir
  )

  $final = if ($Decision -in @('allow', 'deny')) { $Decision } else { 'ask' }
  Write-HarnessBridgeAuditEntry -LogDir $LogDir -Harness $Harness -Tool $Tool -Decision $final -Summary $Summary
  Write-Output (ConvertTo-HarnessApprovalDocument -Harness $Harness -Decision $final)
  exit 0
}

$harnessName = ''
$toolName = ''
$summaryText = ''
$timeoutOverride = 0
$hookMode = $Harness -eq 'hook'

try {
  if ($hookMode) {
    $harnessName = $Tool
    $payloadInfo = Read-HarnessBridgeHookPayload
    $toolName = $payloadInfo.Tool
    $summaryText = $payloadInfo.Summary
  }
  else {
    $harnessName = $Harness
    $toolName = $Tool
    $summaryText = $Summary
    $timeoutOverride = $TimeoutSeconds
  }

  if ([string]::IsNullOrWhiteSpace($harnessName)) {
    Write-HarnessBridgeWarning -CommandName 'harness-approval' -Message 'usage: harness-approval <harness> <tool> <summary> [timeout-seconds] | harness-approval hook <harness>'
    Write-Output 'ask'
    exit 0
  }

  $logDir = Join-Path -Path (Get-HarnessBridgeUserRoot) -ChildPath 'log'
  $configPath = Get-HarnessBridgeConfigPath

  if ([string]::IsNullOrWhiteSpace($toolName)) {
    Write-HarnessBridgeWarning -CommandName 'harness-approval' -Message 'usage: harness-approval <harness> <tool> <summary> [timeout-seconds]'
    Complete-HarnessApproval -Harness $harnessName -Tool '' -Summary '' -Decision 'ask' -LogDir $logDir
  }

  try { $config = Get-HarnessBridgeApprovalConfig -ConfigPath $configPath }
  catch {
    Write-HarnessBridgeWarning -CommandName 'harness-approval' -Message 'could not parse nucleus config — asking locally'
    Complete-HarnessApproval -Harness $harnessName -Tool $toolName -Summary $summaryText -Decision 'ask' -LogDir $logDir
  }

  if (-not $config['harness-notify'].enable) {
    Complete-HarnessApproval -Harness $harnessName -Tool $toolName -Summary $summaryText -Decision 'ask' -LogDir $logDir
  }

  # The remote gate is off by default, so the hooks stay wired (a flag flip is all
  # it takes to re-enable) while every tool call is answered `ask` at once and the
  # harness keeps its own prompt.
  if (-not $config['harness-approval'].enable) {
    Complete-HarnessApproval -Harness $harnessName -Tool $toolName -Summary $summaryText -Decision 'ask' -LogDir $logDir
  }

  $timeout = if ($timeoutOverride -gt 0) { $timeoutOverride } else { [int]$config['harness-approval']['timeout-seconds'] }
  if ($timeout -lt 1) { $timeout = 1 }

  $decision = Request-HarnessApproval -Harness $harnessName -Tool $toolName -Summary $summaryText `
    -TimeoutSeconds $timeout -UserRoot (Get-HarnessBridgeUserRoot)

  Complete-HarnessApproval -Harness $harnessName -Tool $toolName -Summary $summaryText -Decision $decision -LogDir $logDir
}
catch {
  # Fail open: an unreachable broker or an unwritable state directory must not
  # wedge the harness, and must not silently authorise anything either.
  Write-HarnessBridgeWarning -CommandName 'harness-approval' -Message $_.Exception.Message
  $fallbackHarness = if ([string]::IsNullOrWhiteSpace($harnessName)) { 'other' } else { $harnessName }
  Write-Output (ConvertTo-HarnessApprovalDocument -Harness $fallbackHarness -Decision 'ask')
}

exit 0
