#Requires -Version 7.4
# WHY: grep-based — the defect guarded here is a divergence between the ai
# twins: each declares its own model manifest path, and nothing reported the
# disagreement. The broken path lives in this script, which cannot be invoked
# without a live Ollama host, so the only observable surface is the two sources
# compared against each other and against the working tree.
#
# Every assertion runs over *all* paths a twin declares, not just the first.
# PowerShell lets a later assignment silently shadow an earlier one, so a
# script can carry a correct manifest path and then a wrong one that wins at
# runtime, and a first-match-only guard reads green on that broken script.
# Windows twin of ai-manifest-parity-tests.sh.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:passCount = 0
$script:failCount = 0
$script:AiDocumentedManifest = ''

$repoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '../..')).Path
$aiSh = Join-Path -Path $repoRoot -ChildPath 'scripts/ai.sh'
$aiPs1 = Join-Path -Path $repoRoot -ChildPath 'scripts/ai.ps1'

$git = Get-Command -Name git -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: git may be absent; explicit throw below
if (-not $git) {
  throw 'git is required to run ai-manifest-parity-tests.ps1 (the tracked-file assertion runs git ls-files)'
}

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

# Every manifest path ai.sh declares, forward slashes as written. An empty
# result means the assignment shape changed and nothing is being guarded.
function Get-AiShManifestList {
  $text = Get-Content -LiteralPath $aiSh -Raw
  $found = [regex]::Matches($text, '(?m)^[ \t]*MANIFEST="\$REPO_ROOT/([^"]+)"')
  return @($found | ForEach-Object { $_.Groups[1].Value })
}

# Every manifest path ai.ps1 declares, normalised from backslashes so they
# compare with the sh twin and resolve against the tree.
function Get-AiPs1ManifestList {
  $text = Get-Content -LiteralPath $aiPs1 -Raw
  $found = [regex]::Matches($text, '(?m)^[ \t]*\$ModelsJson[ \t]*=[ \t]*Join-Path[ \t]+\$RepoRoot[ \t]+"([^"]+)"')
  return @($found | ForEach-Object { $_.Groups[1].Value.Replace('\', '/') })
}

# The manifest path as ai.ps1's own help text declares it. Empty when the help
# text does not mention one, which is not a failure on its own.
function Get-AiPs1DocumentedManifest {
  $text = Get-Content -LiteralPath $aiPs1 -Raw
  $m = [regex]::Match($text, '[A-Za-z0-9_./-]*models\.json')
  if ($m.Success) { return $m.Value }
  return ''
}

# Deduplicated, sorted form, so two twins compare as sets: declaring the same
# paths in a different order is not a divergence.
function Get-NormalizedSet {
  param([string[]]$Paths)
  return @($Paths | Where-Object { $_ } | Sort-Object -Unique)
}

function Assert-ShPathResolve {
  param([string]$Path)
  if (Test-Path -LiteralPath (Join-Path -Path $repoRoot -ChildPath $Path)) {
    Assert-Pass -Name "ai.sh manifest path resolves ($Path)"
  } else {
    Assert-Fail -Name 'ai.sh manifest path resolves' -Reason "no such file: $Path"
  }
}

function Assert-Ps1PathResolve {
  param([string]$Path)
  if (Test-Path -LiteralPath (Join-Path -Path $repoRoot -ChildPath $Path)) {
    Assert-Pass -Name "ai.ps1 manifest path resolves ($Path)"
  } else {
    Assert-Fail -Name 'ai.ps1 manifest path resolves' -Reason "no such file: $Path"
  }
}

function Assert-PathTracked {
  param([string]$Path)
  git -C $repoRoot ls-files --error-unmatch -- $Path > $null 2>&1
  if ($LASTEXITCODE -eq 0) {
    Assert-Pass -Name "ai manifest path is tracked ($Path)"
  } else {
    Assert-Fail -Name 'ai manifest path is tracked' -Reason "untracked: $Path"
  }
}

function Assert-Ps1PathDocumented {
  param([string]$Path)
  if ($Path -eq $script:AiDocumentedManifest) {
    Assert-Pass -Name "ai.ps1 help text agrees with the code ($Path)"
  } else {
    Assert-Fail -Name 'ai.ps1 help text agrees with the code' -Reason "help=$script:AiDocumentedManifest code=$Path"
  }
}

function Test-AiManifestPathResolve {
  $shPaths = @(Get-AiShManifestList)
  $ps1Paths = @(Get-AiPs1ManifestList)
  if ($shPaths.Count -eq 0) {
    Assert-Fail -Name 'ai.sh declares a manifest path' -Reason 'no MANIFEST="$REPO_ROOT/..." assignment'
  } else {
    foreach ($p in $shPaths) { Assert-ShPathResolve -Path $p }
  }
  if ($ps1Paths.Count -eq 0) {
    Assert-Fail -Name 'ai.ps1 declares a manifest path' -Reason 'no $ModelsJson = Join-Path $RepoRoot "..." assignment'
  } else {
    foreach ($p in $ps1Paths) { Assert-Ps1PathResolve -Path $p }
  }
}

function Test-AiManifestPathTracked {
  # @() on both operands: PowerShell unrolls a one-element array on return, and
  # string + array concatenates rather than joining, which would fuse every
  # path into one bogus path instead of reporting each one.
  $candidates = @(Get-NormalizedSet -Paths (@(Get-AiShManifestList) + @(Get-AiPs1ManifestList)))
  # An empty set would pass vacuously through a loop that never runs, so the
  # empty case is a failure of this assertion rather than of nothing.
  if ($candidates.Count -eq 0) {
    Assert-Fail -Name 'ai manifest paths are tracked files' -Reason 'no manifest path extracted from either twin'
  } else {
    foreach ($p in $candidates) { Assert-PathTracked -Path $p }
  }
}

function Test-AiManifestPathParity {
  $shPaths = @(Get-AiShManifestList)
  $ps1Paths = @(Get-AiPs1ManifestList)
  if ($shPaths.Count -eq 0 -or $ps1Paths.Count -eq 0) {
    Assert-Fail -Name 'ai twins declare the same manifest paths' -Reason 'extraction failed on at least one twin'
    return
  }
  # Compare the newline-joined form, not the space-joined one: a two-path set
  # and a single path containing a space would flatten to the same string, so a
  # space-joined compare can pass for two different declarations. The
  # space-joined form is for the message only, matching the sh twin.
  $shNorm = @(Get-NormalizedSet -Paths $shPaths)
  $ps1Norm = @(Get-NormalizedSet -Paths $ps1Paths)
  $shFlat = $shNorm -join ' '
  $ps1Flat = $ps1Norm -join ' '
  if (($shNorm -join "`n") -eq ($ps1Norm -join "`n")) {
    Assert-Pass -Name "ai twins declare the same manifest paths ($ps1Flat)"
  } else {
    Assert-Fail -Name 'ai twins declare the same manifest paths' -Reason "ai.sh=[$shFlat] ai.ps1=[$ps1Flat]"
  }
}

function Test-AiPs1HelpTextAgreement {
  $ps1Paths = @(Get-AiPs1ManifestList)
  $script:AiDocumentedManifest = Get-AiPs1DocumentedManifest
  if ($ps1Paths.Count -eq 0) {
    Assert-Fail -Name 'ai.ps1 help text agrees with the code' -Reason 'code path not extractable'
  } elseif (-not $script:AiDocumentedManifest) {
    Assert-Pass -Name 'ai.ps1 help text declares no manifest path, so nothing to contradict'
  } else {
    foreach ($p in $ps1Paths) { Assert-Ps1PathDocumented -Path $p }
  }
}

Test-AiManifestPathResolve
Test-AiManifestPathTracked
Test-AiManifestPathParity
Test-AiPs1HelpTextAgreement

Write-Output ''
Write-Output "$script:passCount passed, $script:failCount failed"
if ($script:failCount -gt 0) { exit 1 }
exit 0
