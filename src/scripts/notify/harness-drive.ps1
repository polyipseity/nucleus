<#
.SYNOPSIS
  Ends a harness turn on Windows: notify, then inject one queued remote prompt.

.DESCRIPTION
  Windows twin of harness-drive.sh.  Every "the agent stopped" hook calls this
  instead of harness-notify, because the same moment is when a prompt queued with
  `/harness send <harness> <text>` can be delivered.  The stop-hook payload on
  stdin is forwarded to harness-notify.ps1 <harness> done, so the notification
  half keeps one definition.

  Continuation document (stdout) — exactly one queued prompt is consumed:

    cursor   {"followup_message":"<text>"}                       (Cursor native)
    copilot  {"hookSpecificOutput":{"hookEventName":"Stop",
              "decision":"block","reason":"<text>"}}             (VS Code native)
    others   no output (pi and opencode are driven through their own APIs)

  With nothing queued, cursor and copilot receive {} and the others nothing.

  One prompt per turn, consumed before it is printed: the queue is the only loop
  guard, so a command file can never be delivered twice.

  Cursor ignores `followup_message` on Windows (forum.cursor.com/t/155078: valid
  JSON, exit 0, agent does not continue), so remote driving of Cursor sessions
  works on macOS and NixOS only.  Nothing here compensates for that: a workaround
  would have to fake user input into the harness.

  This file is deployed verbatim to <USER root>\bin and reached from harness
  hooks through the %USERPROFILE%\.local\bin\harness-drive.cmd shim, so it is
  deliberately self-contained: importing the shared Format-NucleusOutput module
  would require a repository path baked into the deployed copy.  The warning
  helper below still emits the F1 shape (`<cmd>: warning: <msg>`) to stderr.

.PARAMETER Harness
  Harness name: pi, opencode, cursor, or copilot.

.EXAMPLE
  '{"hook_event_name":"Stop"}' | pwsh -NoProfile -File harness-drive.ps1 copilot

.EXAMPLE
  pwsh -NoProfile -File harness-drive.ps1 cursor

.NOTES
  Exit codes: always 0.  A stop hook that fails is surfaced as a failed turn, so
  no part of this path may block the harness.

  Config (~\.local\state\nucleus\config.json, `nucleus-config`):
    harness-notify.enable  boolean, default true; false disables the whole bridge,
                           so nothing is drained and nothing is injected.
    harness-drive.enable   boolean, default true; false keeps the completion
                           notification but never injects a queued prompt.
#>

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$Harness
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
    throw 'harness-drive: %LOCALAPPDATA% is unset; the nucleus USER root is undefined'
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

function Get-HarnessBridgeDriveConfig {
  <#
  .SYNOPSIS
    Reads the master flag and the drive gate over the declared defaults.
  .DESCRIPTION
    Keeps the config sections apart: both sections declare an enable flag, and
    flattening them into one hashtable would let the drive flag shadow the
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
    'harness-drive'  = @{ enable = $true }
    'harness-notify' = @{ enable = $true }
  }
  if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return $config }
  $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($raw)) { return $config }

  # Malformed JSON throws: the caller treats that as "not driving", matching the
  # POSIX twin.
  $parsed = ConvertFrom-Json -InputObject $raw -AsHashtable
  if ($parsed -isnot [hashtable]) { return $config }

  foreach ($sectionName in @('harness-drive', 'harness-notify')) {
    if (-not $parsed.ContainsKey($sectionName)) { continue }
    $section = $parsed[$sectionName]
    if ($section -isnot [hashtable]) { continue }
    foreach ($key in $section.Keys) { $config[$sectionName][$key] = $section[$key] }
  }
  return $config
}

function ConvertTo-HarnessDriveDocument {
  <#
  .SYNOPSIS
    Renders the continuation in the calling harness's own vocabulary.
  .DESCRIPTION
    Encoding always goes through ConvertTo-Json: a hand-built document would
    break on the first quote, backslash, or newline in a prompt.  Harnesses
    without a stop-hook continuation document yield $null, which the caller
    writes nothing for.
  .PARAMETER Harness
    Calling harness name.
  .PARAMETER Text
    Queued prompt to inject.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$Harness,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Text
  )

  switch ($Harness) {
    'cursor' {
      return (ConvertTo-Json -InputObject @{ followup_message = $Text } -Compress -Depth 5)
    }
    'copilot' {
      return (ConvertTo-Json -InputObject @{
          hookSpecificOutput = @{
            hookEventName = 'Stop'
            decision      = 'block'
            reason        = $Text
          }
        } -Compress -Depth 5)
    }
    default { return $null }
  }
}

function Get-HarnessDriveEmptyDocument {
  <#
  .SYNOPSIS
    Renders the "nothing queued" answer for harnesses that expect a document.
  .PARAMETER Harness
    Calling harness name.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$Harness
  )

  switch ($Harness) {
    'cursor' { return '{}' }
    'copilot' { return '{}' }
    default { return $null }
  }
}

function Get-QueuedHarnessPrompt {
  <#
  .SYNOPSIS
    Reads the newest queued prompt for one harness.
  .DESCRIPTION
    Newest by file name: the bridge names each entry "<epoch>-<id>.json", so an
    ordinal maximum is the most recently queued prompt.  Nothing is deleted here;
    the caller consumes the file before printing its text.
  .PARAMETER CommandDir
    Absolute path to the harness's command queue directory.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)]
    [string]$CommandDir
  )

  if (-not (Test-Path -LiteralPath $CommandDir -PathType Container)) { return $null }

  # check-suppress:suppression_doc: an unreadable queue directory means nothing is queued; the caller answers "nothing queued"
  $files = @(Get-ChildItem -LiteralPath $CommandDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
  $newest = $null
  foreach ($file in $files) {
    if ($null -eq $newest -or [string]::CompareOrdinal($file.Name, $newest.Name) -gt 0) { $newest = $file }
  }
  if ($null -eq $newest) { return $null }

  $text = ''
  try {
    $queued = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $newest.FullName -Raw -Encoding UTF8) -AsHashtable
    if ($queued -is [hashtable] -and $queued.ContainsKey('text') -and $null -ne $queued['text']) {
      $text = [string]$queued['text']
    }
  }
  catch {
    Write-HarnessBridgeWarning -CommandName 'harness-drive' -Message "could not read the queued prompt '$($newest.FullName)' — treating it as empty"
    $text = ''
  }

  return @{ Path = $newest.FullName; Text = $text }
}

function Clear-QueuedHarnessPrompt {
  <#
  .SYNOPSIS
    Discards every queued prompt for one harness and audits the drop.
  .DESCRIPTION
    Used when remote driving is switched off.  A prompt queued while driving is
    off can never be delivered, and delivering it hours later (after the flag is
    toggled back) would be worse than dropping it.
  .PARAMETER Harness
    Harness whose queue is emptied.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Harness
  )

  $commandsDir = Join-Path -Path (Get-HarnessBridgeUserRoot) -ChildPath 'state\harness-bridge\commands'
  $commandDir = Join-Path -Path $commandsDir -ChildPath $Harness
  if (-not (Test-Path -LiteralPath $commandDir -PathType Container)) { return }

  # check-suppress:suppression_doc: an unreadable queue directory means there is nothing to drop
  $files = @(Get-ChildItem -LiteralPath $commandDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
  $dropped = 0
  foreach ($file in $files) {
    try {
      Remove-Item -LiteralPath $file.FullName -Force
      $dropped++
    }
    catch {
      Write-HarnessBridgeWarning -CommandName 'harness-drive' -Message "could not discard the queued prompt '$($file.Name)'"
    }
  }
  if ($dropped -eq 0) { return }

  Write-HarnessDriveAuditEntry -Harness $Harness -Detail "dropped $dropped queued prompt(s)"
  Write-HarnessBridgeWarning -CommandName 'harness-drive' -Message "harness-drive is disabled — dropped $dropped queued prompt(s)"
}

function Write-HarnessDriveAuditEntry {
  <#
  .SYNOPSIS
    Appends one line to the harness-bridge audit log.
  .PARAMETER Harness
    Harness the entry is about.
  .PARAMETER Detail
    What happened to that harness's queue.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Harness,

    [Parameter(Mandatory)]
    [string]$Detail
  )

  try {
    $logDir = Join-Path -Path (Get-HarnessBridgeUserRoot) -ChildPath 'log'
    $null = New-Item -ItemType Directory -Path $logDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded
    $line = @(
      [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
      $Harness
      'drive'
      'disabled'
      $Detail
    ) -join "`t"
    Add-Content -LiteralPath (Join-Path -Path $logDir -ChildPath 'harness-bridge.log') -Value $line -Encoding utf8
  }
  catch {
    Write-HarnessBridgeWarning -CommandName 'harness-drive' -Message 'could not write the harness-bridge audit log'
  }
}

function Send-HarnessDriveNotification {
  <#
  .SYNOPSIS
    Forwards the stop-hook payload to harness-notify as a `done` event.
  .DESCRIPTION
    WHY a child process: harness-drive has already consumed the hook's standard
    input, and an in-process `&` call would hand harness-notify the drained
    console stream instead of the payload.  A child pwsh receives the payload as
    real standard input, exactly like the POSIX twin pipes it.
  .PARAMETER Harness
    Harness whose turn ended.
  .PARAMETER Payload
    Raw stop-hook payload, or an empty string when there was none.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Harness,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Payload
  )

  $notifyPath = Join-Path -Path $PSScriptRoot -ChildPath 'harness-notify.ps1'
  # check-suppress:suppression_doc: several pwsh wrappers can sit on PATH and absence is handled right below
  $pwshCli = Get-Command -Name 'pwsh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $pwshCli) {
    Write-HarnessBridgeWarning -CommandName 'harness-drive' -Message 'pwsh is not on PATH — notification dropped'
    return
  }

  try {
    $Payload | & $pwshCli.Source -NoProfile -ExecutionPolicy Bypass -File $notifyPath $Harness 'done'
  }
  catch {
    Write-HarnessBridgeWarning -CommandName 'harness-drive' -Message 'notification failed — continuing to the queued prompt'
    return
  }
  if ($LASTEXITCODE -ne 0) {
    Write-HarnessBridgeWarning -CommandName 'harness-drive' -Message 'notification failed — continuing to the queued prompt'
  }
}

# WHY: strict mode errors on reading an uninitialized variable, and
# $LASTEXITCODE only exists after the first native command.
$global:LASTEXITCODE = 0

try {
  if ([string]::IsNullOrWhiteSpace($Harness)) {
    Write-HarnessBridgeWarning -CommandName 'harness-drive' -Message 'usage: harness-drive <harness>'
    exit 0
  }

  try {
    $config = Get-HarnessBridgeDriveConfig -ConfigPath (Get-HarnessBridgeConfigPath)
  }
  catch {
    Write-HarnessBridgeWarning -CommandName 'harness-drive' -Message 'could not parse nucleus config — not driving'
    $empty = Get-HarnessDriveEmptyDocument -Harness $Harness
    if (-not [string]::IsNullOrWhiteSpace($empty)) { Write-Output $empty }
    exit 0
  }

  if (-not $config['harness-notify'].enable) {
    $empty = Get-HarnessDriveEmptyDocument -Harness $Harness
    if (-not [string]::IsNullOrWhiteSpace($empty)) { Write-Output $empty }
    exit 0
  }

  $payload = ''
  if ([Console]::IsInputRedirected) { $payload = [Console]::In.ReadToEnd() }

  # The notification half shares one implementation; an empty payload still means
  # "the turn finished", which is what harness-notify turns into its default body.
  Send-HarnessDriveNotification -Harness $Harness -Payload $payload

  # Driving has its own gate, checked after the notification: with driving off the
  # turn is still announced, it just never continues.
  if (-not $config['harness-drive'].enable) {
    Clear-QueuedHarnessPrompt -Harness $Harness
    $empty = Get-HarnessDriveEmptyDocument -Harness $Harness
    if (-not [string]::IsNullOrWhiteSpace($empty)) { Write-Output $empty }
    exit 0
  }

  $commandsDir = Join-Path -Path (Get-HarnessBridgeUserRoot) -ChildPath 'state\harness-bridge\commands'
  $queued = Get-QueuedHarnessPrompt -CommandDir (Join-Path -Path $commandsDir -ChildPath $Harness)

  if ($null -eq $queued) {
    $empty = Get-HarnessDriveEmptyDocument -Harness $Harness
    if (-not [string]::IsNullOrWhiteSpace($empty)) { Write-Output $empty }
    exit 0
  }

  if ([string]::IsNullOrWhiteSpace($queued.Text)) {
    Write-HarnessBridgeWarning -CommandName 'harness-drive' -Message 'queued prompt is empty — nothing to inject'
    try {
      Remove-Item -LiteralPath $queued.Path -Force
    }
    catch {
      Write-HarnessBridgeWarning -CommandName 'harness-drive' -Message 'could not discard the empty queued prompt'
    }
    $empty = Get-HarnessDriveEmptyDocument -Harness $Harness
    if (-not [string]::IsNullOrWhiteSpace($empty)) { Write-Output $empty }
    exit 0
  }

  # Consume before printing: if the delete fails, delivering the prompt anyway
  # would let the next turn deliver it again, so the prompt is dropped instead.
  try {
    Remove-Item -LiteralPath $queued.Path -Force
  }
  catch {
    Write-HarnessBridgeWarning -CommandName 'harness-drive' -Message 'could not consume the queued prompt — dropping it to avoid double delivery'
    $empty = Get-HarnessDriveEmptyDocument -Harness $Harness
    if (-not [string]::IsNullOrWhiteSpace($empty)) { Write-Output $empty }
    exit 0
  }

  $document = ConvertTo-HarnessDriveDocument -Harness $Harness -Text $queued.Text
  if (-not [string]::IsNullOrWhiteSpace($document)) { Write-Output $document }
}
catch {
  Write-HarnessBridgeWarning -CommandName 'harness-drive' -Message $_.Exception.Message
}

exit 0
