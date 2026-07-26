<#
.SYNOPSIS
  Collects unique command names from PowerShell files and resolves real CommandInfo objects.

.DESCRIPTION
  Extracted from Initialize-PSScriptAnalyzerCache (optimize-pssa-cache.ps1) into a
  separate, testable module. Provides two utility functions:

  1. Get-UniqueCommandNames — parses .ps1 files and returns the set of unique command
     names found, including expanded Get-* variants.
  2. Get-MatchingRealCommands — batch-resolves command names against Get-Command and
     returns a hashtable of name → real CommandInfo objects (CmdletInfo, FunctionInfo),
     with PSObject unwrapping.

  These functions have no dependency on PSScriptAnalyzer internals and can be reused
  by any PowerShell tooling that needs to discover or resolve commands used in scripts.

.PARAMETER Files
  One or more .ps1 file paths to parse for command names.

.PARAMETER CommandNames
  One or more command names to resolve against loaded commands.

.EXAMPLE
  $names = Get-UniqueCommandNames -Files src/hosts/Windows/apply.ps1
  $map = Get-MatchingRealCommands -CommandNames @($names)
  $map["Write-Output"] → CmdletInfo

.NOTES
  PSObject unwrapping: Get-Command on PowerShell 7 may return PSObject-wrapped results.
  Get-MatchingRealCommands unwraps via .PSObject.BaseObject. This was verified on PS7
  (macOS Apple Silicon). On Windows PowerShell 5.1, unwrapping may not be needed.

  Get- prefix expansion: for each command name not starting with "Get-", the function
  also adds "Get-$name" because PSScriptAnalyzer's AvoidAlias rule checks both forms.
  This mirrors the behavior of Initialize-PSScriptAnalyzerCache.
#>

function Get-UniqueCommandNames {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Files
  )

  $allNames = [System.Collections.Generic.HashSet[string]]::new()
  foreach ($f in $Files) {
    if (-not (Test-Path -Path $f)) { continue }
    $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$null)
    $cmdNames = $fileAst.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true) |
      ForEach-Object { $_.GetCommandName() } | Where-Object { $_ }
    foreach ($n in $cmdNames) {
      $null = $allNames.Add($n)
      if ($n -notlike 'Get-*') { $null = $allNames.Add("Get-$n") }
    }
  }
  return $allNames
}

function Get-MatchingRealCommands {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$CommandNames
  )

  $nameSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$CommandNames, [System.StringComparer]::OrdinalIgnoreCase)
  $realCmds = @(Get-Command -CommandType Cmdlet, Function, Filter -ErrorAction SilentlyContinue)  # check-suppress:suppression_doc: Get-Command may fail in constrained language mode or minimal CI environments; empty result handled by [hashtable] return below.
  $result = @{}
  foreach ($cmd in $realCmds) {
    $unwrapped = if ($cmd -is [System.Management.Automation.PSObject]) { $cmd.PSObject.BaseObject } else { $cmd }
    if ($unwrapped -is [System.Management.Automation.CommandInfo] -and $nameSet.Contains($unwrapped.Name)) {
      $result[$unwrapped.Name] = $unwrapped
    }
  }
  return $result
}
