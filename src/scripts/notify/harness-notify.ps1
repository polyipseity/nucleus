<#
.SYNOPSIS
  Normalizes a coding-harness lifecycle event into a Hermes notification (Windows).

.DESCRIPTION
  Windows twin of harness-notify.sh: every provisioned harness (pi, opencode,
  Cursor, VS Code Copilot Chat) funnels its hook payload through one entry point
  so message formatting, channel selection, and failure handling have one
  definition.

  Delivery goes through `hermes send`, which reuses the platform credentials and
  channel configuration the Hermes gateway already owns, so nucleus stores no
  bot tokens of its own for notifications and no gateway process needs to be
  running for bot-token platforms.

  This file is deployed verbatim to <USER root>\bin and reached from harness
  hooks through the %USERPROFILE%\.local\bin\harness-notify.cmd shim, so it is
  deliberately self-contained: importing the shared Format-NucleusOutput module
  would require a repository path baked into the deployed copy.  The warning
  helper below still emits the F1 shape (`<cmd>: warning: <msg>`) to stderr.

.PARAMETER Harness
  Harness name: pi, opencode, cursor, or copilot.

.PARAMETER EventName
  Lifecycle event: done, needs-input, approval, or error.  Named EventName
  because PowerShell reserves `Event` as an automatic variable.

.PARAMETER Text
  Optional body.  When omitted, stdin is read: raw text, or a hook JSON object
  from which .message/.prompt/.text/.tool_name is extracted.

.EXAMPLE
  pwsh -NoProfile -File harness-notify.ps1 pi done 'finished the refactor'

.EXAMPLE
  '{"message":"session idle"}' | pwsh -NoProfile -File harness-notify.ps1 opencode done

.NOTES
  Exit codes: always 0.  A notification is best-effort; it must never block or
  fail the harness that emitted it, and hook runners treat a non-zero exit as a
  denial in some harnesses.

  Config (~\.local\state\nucleus\config.json, `nucleus-config`):
    harness-notify.enable    boolean, default true
    harness-notify.channels  array of `hermes send` targets
    harness-notify.max-chars integer body cap, default 1200

    The other two gates belong to their own entry points and do not change what
    this script sends: harness-approval.enable (default false) answers tool calls
    locally, and harness-drive.enable (default true) decides whether a queued
    prompt is injected after a finished turn.
#>

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$Harness,

  [Parameter(Position = 1)]
  [string]$EventName,

  [Parameter(Position = 2)]
  [string]$Text
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-HarnessBridgeWarning {
  <#
  .SYNOPSIS
    Writes one F1 warning line to stderr without importing the shared module.
  .DESCRIPTION
    See the file header: this script is deployed outside the repository, so it
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

function Get-HarnessBridgeNotifyConfig {
  <#
  .SYNOPSIS
    Reads the harness-notify config section merged over the declared defaults.
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
    enable      = $true
    channels    = @('telegram', 'ntfy', 'discord')
    'max-chars' = 1200
  }

  if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return $config }
  $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($raw)) { return $config }

  # Malformed JSON throws: the caller treats that as "not notifying", matching
  # the POSIX twin.
  $parsed = ConvertFrom-Json -InputObject $raw -AsHashtable
  if ($parsed -isnot [hashtable] -or -not $parsed.ContainsKey('harness-notify')) { return $config }
  $section = $parsed['harness-notify']
  if ($section -isnot [hashtable]) { return $config }

  foreach ($key in $section.Keys) { $config[$key] = $section[$key] }
  return $config
}

function Send-HarnessNotification {
  <#
  .SYNOPSIS
    Fans one normalized lifecycle event out to every configured Hermes channel.
  .PARAMETER Harness
    Harness name used as the subject prefix.
  .PARAMETER Event
    Normalized event name.
  .PARAMETER Text
    Optional body; the event label is used when it is empty.
  .PARAMETER ConfigPath
    Absolute path to the nucleus runtime config file.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Harness,

    [Parameter(Mandatory)]
    [ValidateSet('done', 'needs-input', 'approval', 'error')]
    [string]$EventName,

    [string]$Text,

    [Parameter(Mandatory)]
    [string]$ConfigPath
  )

  try {
    $config = Get-HarnessBridgeNotifyConfig -ConfigPath $ConfigPath
  }
  catch {
    Write-HarnessBridgeWarning -CommandName 'harness-notify' -Message 'could not parse nucleus config — not notifying'
    return
  }

  if (-not $config.enable) { return }

  $label = switch ($EventName) {
    'done' { 'finished' }
    'needs-input' { 'needs input' }
    'approval' { 'approval needed' }
    default { 'error' }
  }

  if ([string]::IsNullOrWhiteSpace($Text)) { $Text = $label }
  $maxChars = [int]$config['max-chars']
  if ($maxChars -gt 0 -and $Text.Length -gt $maxChars) { $Text = $Text.Substring(0, $maxChars) }

  # WHY: selecting the first match mirrors how a shell resolves a bare command;
  # more than one hermes on PATH otherwise yields a list, which cannot be invoked.
  $hermes = Get-Command -Name 'hermes' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1  # check-suppress:suppression_doc: absence is the expected case and is reported right below
  if ($null -eq $hermes) {
    Write-HarnessBridgeWarning -CommandName 'harness-notify' -Message 'hermes is not on PATH — notification dropped'
    return
  }

  $subject = "[$Harness] $label"
  foreach ($target in @($config.channels)) {
    if ([string]::IsNullOrWhiteSpace([string]$target)) { continue }
    $targetText = [string]$target
    $Text | & $hermes.Source send --to $targetText --subject $subject --file - --quiet
    if ($LASTEXITCODE -ne 0) {
      Write-HarnessBridgeWarning -CommandName 'harness-notify' -Message "delivery to '$targetText' failed"
    }
  }
}

# WHY: strict mode errors on reading an uninitialized variable, and
# $LASTEXITCODE only exists after the first native command.
$global:LASTEXITCODE = 0

try {
  if ([string]::IsNullOrWhiteSpace($Harness) -or [string]::IsNullOrWhiteSpace($EventName)) {
    Write-HarnessBridgeWarning -CommandName 'harness-notify' -Message 'usage: harness-notify <harness> <event> [text]'
    exit 0
  }

  if ($EventName -notin @('done', 'needs-input', 'approval', 'error')) {
    Write-HarnessBridgeWarning -CommandName 'harness-notify' -Message "unknown event '$EventName' — not notifying"
    exit 0
  }

  # Body: explicit argument wins, otherwise stdin (raw text or hook JSON).
  if ([string]::IsNullOrWhiteSpace($Text) -and [Console]::IsInputRedirected) {
    $stdin = [Console]::In.ReadToEnd()
    if (-not [string]::IsNullOrWhiteSpace($stdin)) {
      if ($stdin.TrimStart().StartsWith('{')) {
        $payload = $null
        try { $payload = ConvertFrom-Json -InputObject $stdin -AsHashtable }
        catch { $Text = $stdin }
        if ($null -ne $payload -and $payload -is [hashtable]) {
          foreach ($field in @('message', 'prompt', 'text', 'tool_name')) {
            if ($payload.ContainsKey($field) -and -not [string]::IsNullOrWhiteSpace([string]$payload[$field])) {
              $Text = [string]$payload[$field]
              break
            }
          }
        }
      }
      else {
        $Text = $stdin
      }
    }
  }

  Send-HarnessNotification -Harness $Harness -EventName $EventName -Text $Text -ConfigPath (Get-HarnessBridgeConfigPath)
}
catch {
  Write-HarnessBridgeWarning -CommandName 'harness-notify' -Message $_.Exception.Message
}

exit 0
