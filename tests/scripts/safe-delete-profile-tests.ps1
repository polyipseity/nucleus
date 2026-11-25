#Requires -Version 7.4
# Unit tests for Invoke-SafeDelete in src/scripts/shell/profile.ps1.
# Focus: argument shaping. On POSIX the function delegates to safe-rm; on
# Windows it falls back to $script:OriginalRemoveItem for non-filesystem targets.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:passCount = 0
$script:failCount = 0

function Assert-Pass([string]$Name) {
  Write-Output "PASS $Name"
  $script:passCount++
}

function Assert-Fail([string]$Name, [string]$Reason) {
  Write-Output "FAIL $Name : $Reason"
  $script:failCount++
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$profilePath = Join-Path $repoRoot 'src/scripts/shell/profile.ps1'

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($profilePath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
  throw ($errors | ForEach-Object Message | Join-String -Separator '; ')
}
$fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-SafeDelete' }, $true) | Select-Object -First 1
if (-not $fn) { throw 'Invoke-SafeDelete not found in profile.ps1' }
. ([scriptblock]::Create($fn.Extent.Text))

# POSIX in-process stub: records delegated argument shape. Created as a function
# item rather than a function definition because the name is fixed by the
# production call site and safe is not an approved PowerShell verb.
$script:SafeRmCalls = @()
$safeRmStub = {
  [CmdletBinding()]
  param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [object[]]$CapturedArgs
  )
  $script:SafeRmCalls += , @($CapturedArgs)
}
Set-Item -Path 'function:global:safe-rm' -Value $safeRmStub

# Windows fallback stub: records the shaped parameters passed to OriginalRemoveItem.
$script:OriginalRemoveItemCalls = @()
function Get-OriginalRemoveItemStub {
  return {
    [CmdletBinding()]
    param(
      [Parameter(ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
      [string[]]$Path,
      [Parameter(ValueFromPipelineByPropertyName = $true)]
      [string[]]$LiteralPath,
      [Switch]$Recurse,
      [Switch]$Force,
      [string]$Filter,
      [string[]]$Include,
      [string[]]$Exclude,
      [Switch]$WhatIf,
      [Switch]$Confirm
    )
    process {
      $script:OriginalRemoveItemCalls += , [pscustomobject]@{
        Path        = @($Path)
        LiteralPath = @($LiteralPath)
        Recurse     = [bool]$Recurse
        Force       = [bool]$Force
        Filter      = $Filter
        Include     = @($Include)
        Exclude     = @($Exclude)
        WhatIf      = [bool]$WhatIf
        Confirm     = [bool]$Confirm
      }
    }
  }
}

function Invoke-SafeDeleteProbe {
  param(
    [Parameter(Mandatory)][scriptblock]$Expression
  )

  $script:SafeRmCalls = @()
  $script:OriginalRemoveItemCalls = @()
  $script:OriginalRemoveItem = $null
  if ($IsWindows) {
    $script:OriginalRemoveItem = Get-OriginalRemoveItemStub
  }
  try {
    & $Expression
  }
  finally {
    $script:OriginalRemoveItem = $null
  }

  if ($IsWindows) {
    return [pscustomobject]@{
      Backend = 'windows-fallback'
      Calls   = @($script:OriginalRemoveItemCalls)
    }
  }
  return [pscustomobject]@{
    Backend = 'posix-safe-rm'
    Calls   = @($script:SafeRmCalls)
  }
}

function Assert-PosixCall {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Calls,
    [Parameter(Mandatory)][string[]]$Expected
  )

  if ($Calls.Count -ne 1) {
    Assert-Fail $Name "expected 1 safe-rm call, got $($Calls.Count)"
    return
  }
  $actual = @($Calls[0] | ForEach-Object { [string]$_ })
  if ($actual.Count -ne $Expected.Count) {
    Assert-Fail $Name "expected [$($Expected -join ', ')], got [$($actual -join ', ')]"
    return
  }
  for ($i = 0; $i -lt $Expected.Count; $i++) {
    if ($actual[$i] -ne $Expected[$i]) {
      Assert-Fail $Name "expected [$($Expected -join ', ')], got [$($actual -join ', ')]"
      return
    }
  }
  Assert-Pass $Name
}

function Assert-WindowsFallbackCall {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Calls,
    [string[]]$ExpectedPath = @(),
    [string[]]$ExpectedLiteralPath = @(),
    [bool]$ExpectedRecurse = $false,
    [bool]$ExpectedForce = $false
  )

  if ($Calls.Count -ne 1) {
    Assert-Fail $Name "expected 1 OriginalRemoveItem call, got $($Calls.Count)"
    return
  }
  $call = $Calls[0]
  $actualPath = @($call.Path | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
  $actualLiteral = @($call.LiteralPath | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
  $expectedPathValues = @($ExpectedPath | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
  $expectedLiteralValues = @($ExpectedLiteralPath | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })

  if (($actualPath -join "`n") -ne ($expectedPathValues -join "`n")) {
    Assert-Fail $Name "expected Path [$($expectedPathValues -join ', ')], got [$($actualPath -join ', ')]"
    return
  }
  if (($actualLiteral -join "`n") -ne ($expectedLiteralValues -join "`n")) {
    Assert-Fail $Name "expected LiteralPath [$($expectedLiteralValues -join ', ')], got [$($actualLiteral -join ', ')]"
    return
  }
  if ([bool]$call.Recurse -ne $ExpectedRecurse) {
    Assert-Fail $Name "expected Recurse=$ExpectedRecurse, got $($call.Recurse)"
    return
  }
  if ([bool]$call.Force -ne $ExpectedForce) {
    Assert-Fail $Name "expected Force=$ExpectedForce, got $($call.Force)"
    return
  }
  Assert-Pass $Name
}

function Get-MissingPath([string]$Leaf) {
  return Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-safe-delete-missing-" + [System.Guid]::NewGuid().ToString('N') + '-' + $Leaf)
}

function Test-SinglePathNotCharSplatted {
  $missing = Get-MissingPath 'ab'
  $probe = Invoke-SafeDeleteProbe -Expression { Invoke-SafeDelete $missing }
  if ($probe.Backend -eq 'posix-safe-rm') {
    Assert-PosixCall -Name 'single-path-not-char-splatted' -Calls $probe.Calls -Expected @($missing)
    return
  }
  Assert-WindowsFallbackCall -Name 'single-path-not-char-splatted' -Calls $probe.Calls -ExpectedPath @($missing) -ExpectedLiteralPath @()
}

function Test-MultiplePathsPreserved {
  $missing1 = Get-MissingPath 'ab'
  $missing2 = Get-MissingPath 'cd'
  $probe = Invoke-SafeDeleteProbe -Expression { Invoke-SafeDelete -Path @($missing1, $missing2) }
  if ($probe.Backend -eq 'posix-safe-rm') {
    Assert-PosixCall -Name 'multiple-paths-preserved' -Calls $probe.Calls -Expected @($missing1, $missing2)
    return
  }
  Assert-WindowsFallbackCall -Name 'multiple-paths-preserved' -Calls $probe.Calls -ExpectedPath @($missing1, $missing2) -ExpectedLiteralPath @()
}

function Test-LiteralPathSinglePath {
  $missing = Get-MissingPath 'ab'
  $probe = Invoke-SafeDeleteProbe -Expression { Invoke-SafeDelete -LiteralPath $missing }
  if ($probe.Backend -eq 'posix-safe-rm') {
    Assert-PosixCall -Name 'literalpath-single-path' -Calls $probe.Calls -Expected @($missing)
    return
  }
  Assert-WindowsFallbackCall -Name 'literalpath-single-path' -Calls $probe.Calls -ExpectedPath @() -ExpectedLiteralPath @($missing)
}

function Test-RecurseForceStillBind {
  $missing = Get-MissingPath 'ab'
  $probe = Invoke-SafeDeleteProbe -Expression { Invoke-SafeDelete -Recurse -Force $missing }
  if ($probe.Backend -eq 'posix-safe-rm') {
    Assert-PosixCall -Name 'recurse-force-still-bind' -Calls $probe.Calls -Expected @($missing)
    return
  }
  Assert-WindowsFallbackCall -Name 'recurse-force-still-bind' -Calls $probe.Calls -ExpectedPath @($missing) -ExpectedLiteralPath @() -ExpectedRecurse $true -ExpectedForce $true
}

Write-Output '=== safe-delete-profile tests ==='
Test-SinglePathNotCharSplatted
Test-MultiplePathsPreserved
Test-LiteralPathSinglePath
Test-RecurseForceStillBind

Write-Output ''
Write-Output "safe-delete-profile: $($script:passCount) passed, $($script:failCount) failed"
if ($script:failCount -gt 0) { exit 1 }
exit 0
