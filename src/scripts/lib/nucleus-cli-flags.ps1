#Requires -Version 7.0
# nucleus-cli-flags.ps1 - normalizes --list-* kebab flags to PowerShell switch params
# and validates positional Action values after normalization.
#
# Dot-source from directly invocable PowerShell scripts. Prefer [Alias('list-x')] on
# the switch param (prevents param-binding failures). Call Resolve-NucleusCliFlag
# as a defensive fallback for the case where a --list-* flag was bound as a positional
# Action, and from hand-parsed scripts to normalize args arrays.

function Resolve-NucleusCliFlag {
  <#
  .SYNOPSIS
    Maps --list-<x> / -list-<x> forms to switch variables.
  .PARAMETER Action
    Ref to the positional Action string. Cleared when a list flag is consumed.
  .PARAMETER Flags
    Hashtable mapping the kebab name (without leading dashes, e.g. 'list-logs')
    to the switch variable name (e.g. 'ListLogs').
  .PARAMETER Arguments
    Optional argument array to scan. Consumed tokens are removed.
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory = $true)]
    [ref]$Action,

    [Parameter(Mandatory = $true)]
    [hashtable]$Flags,

    [string[]]$Arguments = @()
  )

  $raw = [string]$Action.Value
  if (-not [string]::IsNullOrWhiteSpace($raw)) {
    $normalized = $raw.TrimStart('-')
    foreach ($key in $Flags.Keys) {
      if ($normalized.Equals($key, [System.StringComparison]::OrdinalIgnoreCase)) {
        Set-Variable -Name $Flags[$key] -Value $true -Scope 1
        $Action.Value = ''
        break
      }
    }
  }

  if ($Arguments.Count -eq 0) {
    Write-Output -NoEnumerate -InputObject ([string[]]@())
    return
  }

  $remaining = [System.Collections.Generic.List[string]]::new()
  foreach ($arg in $Arguments) {
    $n = ([string]$arg).TrimStart('-')
    $matched = $false
    foreach ($key in $Flags.Keys) {
      if ($n.Equals($key, [System.StringComparison]::OrdinalIgnoreCase)) {
        Set-Variable -Name $Flags[$key] -Value $true -Scope 1
        $matched = $true
        break
      }
    }
    if (-not $matched) { $remaining.Add([string]$arg) }
  }
  Write-Output -NoEnumerate -InputObject ([string[]]$remaining.ToArray())
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
