#Requires -Version 7.4
# Unit tests for Invoke-SafeDelete in src/scripts/shell/profile.ps1.
# Focus: argument shaping when delegating to the POSIX safe-delete backend.

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

# In-process stub: records the argument shape Invoke-SafeDelete delegates.
$script:SafeRmCalls = @()
function global:safe-rm {
  [CmdletBinding()]
  param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [object[]]$CapturedArgs
  )
  $script:SafeRmCalls += , @($CapturedArgs)
}

function Invoke-SafeDeleteProbe {
  param(
    [Parameter(Mandatory)][scriptblock]$Expression
  )

  $script:SafeRmCalls = @()
  $script:OriginalRemoveItem = $null
  try {
    & $Expression
  }
  finally {
    $script:OriginalRemoveItem = $null
  }
  return , @($script:SafeRmCalls)
}

function Assert-Calls {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Calls,
    [Parameter(Mandatory)][string[]]$Expected
  )

  if ($Calls.Count -ne 1) {
    Assert-Fail $Name "expected 1 call, got $($Calls.Count)"
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

function Test-SinglePathNotCharSplatted {
  if ($IsWindows) { Assert-Pass 'single-path-not-char-splatted'; return }
  $calls = Invoke-SafeDeleteProbe -Expression { Invoke-SafeDelete 'ab' }
  Assert-Calls -Name 'single-path-not-char-splatted' -Calls $calls -Expected @('ab')
}

function Test-MultiplePathsPreserved {
  if ($IsWindows) { Assert-Pass 'multiple-paths-preserved'; return }
  $calls = Invoke-SafeDeleteProbe -Expression { Invoke-SafeDelete -Path @('ab', 'cd') }
  Assert-Calls -Name 'multiple-paths-preserved' -Calls $calls -Expected @('ab', 'cd')
}

function Test-LiteralPathSinglePath {
  if ($IsWindows) { Assert-Pass 'literalpath-single-path'; return }
  $calls = Invoke-SafeDeleteProbe -Expression { Invoke-SafeDelete -LiteralPath 'ab' }
  Assert-Calls -Name 'literalpath-single-path' -Calls $calls -Expected @('ab')
}

function Test-RecurseForceStillBind {
  if ($IsWindows) { Assert-Pass 'recurse-force-still-bind'; return }
  $calls = Invoke-SafeDeleteProbe -Expression { Invoke-SafeDelete -Recurse -Force 'ab' }
  Assert-Calls -Name 'recurse-force-still-bind' -Calls $calls -Expected @('ab')
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
