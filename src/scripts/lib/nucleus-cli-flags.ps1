#Requires -Version 7.0
# nucleus-cli-flags.ps1 - normalizes --list-* kebab flags to PowerShell switch params.
#
# Dot-source from directly invocable PowerShell scripts. Prefer [Alias('list-x')] on
# the switch param (prevents param-binding failures). Call Resolve-NucleusListFlags
# as a defensive fallback for the case where a --list-* flag was bound as a positional
# Action, and from hand-parsed scripts to normalize args arrays.

function Resolve-NucleusListFlags {
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

  if ($Arguments.Count -eq 0) { return ,@() }

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
  return ,$remaining.ToArray()
}
