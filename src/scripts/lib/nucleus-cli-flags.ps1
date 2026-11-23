#Requires -Version 7.0
# nucleus-cli-flags.ps1 - normalizes CLI arguments and validates positional actions.
#
# Dot-source from directly invocable PowerShell scripts. Use Resolve-NucleusArgument
# to bind --kebab-case flags from raw args to declared param() names.

$script:_NucleusCliSpecCacheTried = $false
$script:_NucleusCliSpecCache = $null
$script:_NucleusCliFlagsLibDir = $PSScriptRoot

function Get-NucleusCliFlagSpecPlatformList {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$CommandName,
    [Parameter(Mandatory)][string]$NormalizedKey
  )
  if (-not $script:_NucleusCliSpecCacheTried) {
    $script:_NucleusCliSpecCacheTried = $true
    $script:_NucleusCliSpecCache = $null
    $specPath = $null
    $repoRoot = $env:NUCLEUS_REPO_ROOT
    if (-not [string]::IsNullOrWhiteSpace($repoRoot)) {
      $candidate = Join-Path $repoRoot 'src/modules/completions/nucleus-cli-spec.json'
      if (Test-Path -LiteralPath $candidate -PathType Leaf) { $specPath = $candidate }
    }
    if ($null -eq $specPath -and -not [string]::IsNullOrWhiteSpace($script:_NucleusCliFlagsLibDir)) {
      $candidate = Join-Path $script:_NucleusCliFlagsLibDir '../../modules/completions/nucleus-cli-spec.json'
      if (Test-Path -LiteralPath $candidate -PathType Leaf) { $specPath = $candidate }
    }
    if ($null -ne $specPath) {
      try {
        $script:_NucleusCliSpecCache = Get-Content -Raw -LiteralPath $specPath | ConvertFrom-Json
      } catch {
        $script:_NucleusCliSpecCache = $null
      }
    }
  }
  $spec = $script:_NucleusCliSpecCache
  if ($null -eq $spec) { return $null }
  $app = @($spec.apps | Where-Object { $_ -and [string]$_.name -eq $CommandName })
  if ($app.Count -eq 0) { return $null }
  $appObj = $app[0]
  foreach ($f in @($appObj.globalFlags)) {
    if ($null -eq $f -or [string]::IsNullOrWhiteSpace([string]$f.long)) { continue }
    $key = (($([string]$f.long).TrimStart('-') -replace '-', '')).ToLowerInvariant()
    if ($key -eq $NormalizedKey) { return $f.platforms }
  }
  foreach ($sc in @($appObj.subcommands)) {
    foreach ($f in @($sc.flags)) {
      if ($null -eq $f -or [string]::IsNullOrWhiteSpace([string]$f.long)) { continue }
      $key = (($([string]$f.long).TrimStart('-') -replace '-', '')).ToLowerInvariant()
      if ($key -eq $NormalizedKey) { return $f.platforms }
    }
  }
  return $null
}

function Resolve-NucleusArgument {
  <#
  .SYNOPSIS
    Normalizes dash-prefixed CLI arguments to PowerShell parameter variables.
  .DESCRIPTION
    Scans remaining arguments for --kebab-case flags, maps them to declared script
    parameters by dash-stripped case-insensitive name (including aliases), and sets
    bound variables in the caller scope. Returns unclaimed non-flag tokens.
  .PARAMETER Arguments
    Remaining arguments to normalize, typically from a ValueFromRemainingArguments parameter.
  .PARAMETER CommandPath
    Path to the caller script; used to reflect declared parameters.
  .PARAMETER CommandName
    Command name used in error messages.
  .PARAMETER PassThroughUnknownFlags
    When set, unknown dash-prefixed tokens are appended to leftover instead of throwing.
    For --unknown=value the whole token is passed through. For --unknown value only the
    flag token is passed through; the next token is left for normal processing.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [AllowNull()]
    [string[]]$Arguments,

    [Parameter(Mandatory = $true)]
    [string]$CommandPath,

    [Parameter(Mandatory = $true)]
    [string]$CommandName,

    [switch]$PassThroughUnknownFlags
  )

  if ($null -eq $Arguments) { $Arguments = [string[]]@() }

  function _throwNucleusCliError([string]$cmd, [string]$msg) {
    # check-suppress:suppression_doc: probe command presence to choose error formatter fallback
    if (Get-Command -Name Write-NucleusError -ErrorAction SilentlyContinue) {
      Write-NucleusError -CommandName $cmd $msg -ErrorAction Continue
    } else {
      [Console]::Error.WriteLine("${cmd}: error: $msg")
    }
    throw "${cmd}: $msg"
  }

  $cmdInfo = Get-Command -Name $CommandPath -ErrorAction Stop
  $map = @{}

  foreach ($kv in $cmdInfo.Parameters.GetEnumerator()) {
    $meta = $kv.Value
    $isCatchAll = $false
    foreach ($attr in $meta.Attributes) {
      if ($attr -is [System.Management.Automation.ParameterAttribute] -and $attr.ValueFromRemainingArguments) {
        $isCatchAll = $true
        break
      }
    }
    if ($isCatchAll) { continue }

    $isSwitch = $meta.SwitchParameter -or ($meta.ParameterType -eq [System.Management.Automation.SwitchParameter])
    $entry = [pscustomobject]@{ Name = $meta.Name; IsSwitch = [bool]$isSwitch }

    $names = [System.Collections.Generic.List[string]]::new()
    $names.Add([string]$meta.Name)
    foreach ($attr in $meta.Attributes) {
      if ($attr -is [System.Management.Automation.AliasAttribute]) {
        foreach ($a in $attr.AliasNames) { $names.Add([string]$a) }
      }
    }

    foreach ($n in $names) {
      $key = (($n -replace '-', '')).ToLowerInvariant()
      if ($map.ContainsKey($key)) {
        $existing = $map[$key]
        if ($existing.Name -ne $entry.Name) {
          _throwNucleusCliError $CommandName "duplicate normalized parameter key '$key' for '$($existing.Name)' and '$($entry.Name)'"
        }
        continue
      }
      $map[$key] = $entry
    }
  }

  $leftover = [System.Collections.Generic.List[string]]::new()
  $currentPlatform = if ($IsWindows) { 'windows' } else { 'posix' }
  $i = 0
  while ($i -lt $Arguments.Count) {
    $tok = [string]$Arguments[$i]
    if ($tok -eq '--') {
      for ($j = $i + 1; $j -lt $Arguments.Count; $j++) { $leftover.Add([string]$Arguments[$j]) }
      break
    }
    if (-not $tok.StartsWith('-') -or $tok -eq '-') {
      $leftover.Add($tok)
      $i++
      continue
    }

    $rawName = $tok.TrimStart('-')
    $value = $null
    $hasValue = $false
    $eq = $rawName.IndexOf('=')
    if ($eq -ge 0) {
      $value = $rawName.Substring($eq + 1)
      $rawName = $rawName.Substring(0, $eq)
      $hasValue = $true
    }

    $key = (($rawName -replace '-', '')).ToLowerInvariant()
    $flagPlatforms = Get-NucleusCliFlagSpecPlatformList -CommandName $CommandName -NormalizedKey $key
    if ($null -ne $flagPlatforms) {
      $allowedPlatforms = @($flagPlatforms)
      if ($allowedPlatforms.Count -gt 0 -and $allowedPlatforms -notcontains $currentPlatform) {
        $belongs = ($allowedPlatforms -join ', ')
        _throwNucleusCliError $CommandName "flag '$tok' is not supported on $currentPlatform (belongs to $belongs)"
      }
    }
    if (-not $map.ContainsKey($key)) {
      if ($PassThroughUnknownFlags) {
        $leftover.Add($tok)
        $i++
        continue
      }
      _throwNucleusCliError $CommandName "unknown flag '$tok'"
    }

    $entry = $map[$key]
    if ($entry.IsSwitch) {
      $switchValue = [System.Management.Automation.SwitchParameter]::Present
      if ($hasValue) {
        $boolVal = $false
        if ([bool]::TryParse($value, [ref]$boolVal)) {
          $switchValue = [System.Management.Automation.SwitchParameter]$boolVal
        } else {
          _throwNucleusCliError $CommandName "invalid boolean value '$value' for switch flag '$tok'"
        }
      }
      Set-Variable -Name $entry.Name -Value $switchValue -Scope 1
      if ($switchValue.IsPresent) {
        $entryName = [string]$entry.Name
        $oppositeName = if ($entryName.StartsWith('No', [System.StringComparison]::Ordinal) -and $entryName.Length -gt 2) { $entryName.Substring(2) } else { "No$entryName" }
        $oppositeKey = (($oppositeName -replace '-', '')).ToLowerInvariant()
        if ($map.ContainsKey($oppositeKey)) {
          $opposite = $map[$oppositeKey]
          if ($opposite.IsSwitch -and $opposite.Name -ne $entry.Name) {
            Set-Variable -Name $opposite.Name -Value ([System.Management.Automation.SwitchParameter]$false) -Scope 1
          }
        }
      }
      $i++
      continue
    }

    if (-not $hasValue) {
      $i++
      if ($i -ge $Arguments.Count) {
        _throwNucleusCliError $CommandName "missing value for flag '$tok'"
      }
      $value = [string]$Arguments[$i]
    }
    Set-Variable -Name $entry.Name -Value $value -Scope 1
    $i++
  }

  if ($leftover.Count -gt 0) {
    Write-Output -InputObject ([string[]]$leftover.ToArray())
  }
}

function Assert-NucleusCliAction {
  <#
  .SYNOPSIS
    Rejects an action that is not in the allowed set.
  .PARAMETER Action
    The action string to validate.
  .PARAMETER Valid
    Allowed action names (case-insensitive comparison).
  .PARAMETER CommandName
    Command name used in the error message.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string[]]$Valid,

    [Parameter(Mandatory = $true)]
    [string]$CommandName
  )

  if ([string]::IsNullOrWhiteSpace($Action)) { return }
  foreach ($v in $Valid) {
    if ($Action.Equals($v, [System.StringComparison]::OrdinalIgnoreCase)) { return }
  }
  $message = "invalid action '$Action' (expected: $($Valid -join ', '))"
  # check-suppress:suppression_doc: probe command presence to choose error formatter fallback
  if (Get-Command -Name Write-NucleusError -ErrorAction SilentlyContinue) {
    Write-NucleusError -CommandName $CommandName $message -ErrorAction Continue
  } else {
    [Console]::Error.WriteLine("${CommandName}: error: $message")
  }
  throw "${CommandName}: $message"
}
