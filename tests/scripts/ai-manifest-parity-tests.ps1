#Requires -Version 7.4
# Windows twin of ai-manifest-parity-tests.sh. The defect guarded here is a
# divergence between the ai twins: each resolves its own model manifest path,
# and nothing reported the disagreement. Both scripts are parsed rather than
# invoked -- invoking ai.ps1 would need a live Ollama host -- so the paths a
# twin actually resolves are extracted and checked against each other and
# against the working tree. The current manifest name is never hardcoded, so
# renaming it later is caught without editing this suite.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:passCount = 0
$script:failCount = 0

$repoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '../..')).Path
$aiSh = Join-Path -Path $repoRoot -ChildPath 'scripts/ai.sh'
$aiPs1 = Join-Path -Path $repoRoot -ChildPath 'scripts/ai.ps1'

function Assert-Pass {
  param([string]$Name)
  Write-Output "PASS $Name"
  $script:passCount++
}

function Assert-Fail {
  param([string]$Name, [string]$Reason)
  Write-Output "FAIL $Name : $Reason"
  $script:failCount++
}

# The path ai.sh hands to jq, forward slashes as written.
function Get-AiShManifest {
  $text = Get-Content -LiteralPath $aiSh -Raw
  $m = [regex]::Match($text, '(?m)^[ \t]*MANIFEST="\$REPO_ROOT/([^"]+)"')
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}

# The path ai.ps1 hands to Test-Path, normalised from backslashes so it compares
# with the sh twin and resolves against the tree.
function Get-AiPs1Manifest {
  $text = Get-Content -LiteralPath $aiPs1 -Raw
  $m = [regex]::Match($text, '(?m)^[ \t]*\$ModelsJson[ \t]*=[ \t]*Join-Path[ \t]+\$RepoRoot[ \t]+"([^"]+)"')
  if (-not $m.Success) { return '' }
  return $m.Groups[1].Value.Replace('\', '/')
}

# The manifest path as ai.ps1's own help text declares it. Empty when the help
# text does not mention one, which is not a failure on its own.
function Get-AiPs1DocumentedManifest {
  $text = Get-Content -LiteralPath $aiPs1 -Raw
  $m = [regex]::Match($text, '[A-Za-z0-9_./-]*models\.json')
  if ($m.Success) { return $m.Value }
  return ''
}

function Test-AiManifestPathsResolve {
  $shPath = Get-AiShManifest
  $ps1Path = Get-AiPs1Manifest

  if (-not $shPath) {
    Assert-Fail -Name 'ai.sh manifest path is extractable' -Reason 'no MANIFEST="$REPO_ROOT/..." assignment'
  } elseif (Test-Path -LiteralPath (Join-Path -Path $repoRoot -ChildPath $shPath)) {
    Assert-Pass -Name "ai.sh manifest path resolves ($shPath)"
  } else {
    Assert-Fail -Name 'ai.sh manifest path resolves' -Reason "no such file: $shPath"
  }

  if (-not $ps1Path) {
    Assert-Fail -Name 'ai.ps1 manifest path is extractable' -Reason 'no $ModelsJson = Join-Path $RepoRoot "..." assignment'
  } elseif (Test-Path -LiteralPath (Join-Path -Path $repoRoot -ChildPath $ps1Path)) {
    Assert-Pass -Name "ai.ps1 manifest path resolves ($ps1Path)"
  } else {
    Assert-Fail -Name 'ai.ps1 manifest path resolves' -Reason "no such file: $ps1Path"
  }
}

function Test-AiManifestPathsAreTracked {
  $shPath = Get-AiShManifest
  $ps1Path = Get-AiPs1Manifest
  $untracked = @()
  foreach ($candidate in @($shPath, $ps1Path)) {
    if (-not $candidate) { continue }
    git -C $repoRoot ls-files --error-unmatch -- $candidate > $null 2>&1
    if ($LASTEXITCODE -ne 0) { $untracked += $candidate }
  }
  if ($untracked.Count -eq 0) {
    Assert-Pass -Name 'ai manifest paths are tracked files'
  } else {
    Assert-Fail -Name 'ai manifest paths are tracked files' -Reason "untracked: $($untracked -join ', ')"
  }
}

function Test-AiManifestPathParity {
  $shPath = Get-AiShManifest
  $ps1Path = Get-AiPs1Manifest
  if (-not $shPath -or -not $ps1Path) {
    Assert-Fail -Name 'ai twins resolve the same manifest' -Reason 'extraction failed on at least one twin'
  } elseif ($shPath -eq $ps1Path) {
    Assert-Pass -Name "ai twins resolve the same manifest ($ps1Path)"
  } else {
    Assert-Fail -Name 'ai twins resolve the same manifest' -Reason "ai.sh=$shPath ai.ps1=$ps1Path"
  }
}

function Test-AiPs1DocumentedManifestAgreement {
  $ps1Path = Get-AiPs1Manifest
  $documented = Get-AiPs1DocumentedManifest
  if (-not $documented) {
    Assert-Pass -Name 'ai.ps1 help text declares no manifest path, so nothing to contradict'
  } elseif (-not $ps1Path) {
    Assert-Fail -Name 'ai.ps1 help text agrees with the code' -Reason 'code path not extractable'
  } elseif ($documented -eq $ps1Path) {
    Assert-Pass -Name "ai.ps1 help text agrees with the code ($ps1Path)"
  } else {
    Assert-Fail -Name 'ai.ps1 help text agrees with the code' -Reason "help=$documented code=$ps1Path"
  }
}

Test-AiManifestPathsResolve
Test-AiManifestPathsAreTracked
Test-AiManifestPathParity
Test-AiPs1DocumentedManifestAgreement

Write-Output ''
Write-Output "$script:passCount passed, $script:failCount failed"
if ($script:failCount -gt 0) { exit 1 }
exit 0
