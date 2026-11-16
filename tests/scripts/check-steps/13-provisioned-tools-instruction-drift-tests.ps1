# Test: repo-policy-data (check step 13) provisioned-tools instruction drift (PowerShell).
#
# Behavioral coverage for the extracted Invoke-ProvisionedToolsInstructionDriftCheck
# helper: fixture pass with managedPackages CLI + desired names present (GUI/font/
# default excluded), missing managed CLI name fails and names it, missing desired
# name fails and names it, missing instruction fails, and pass message/behavior.
#
# WHY fixture repos instead of the full live step action: the step action runs many
# unrelated subchecks; fixture repos isolate the drift check's source-derived logic
# and parity with the POSIX implementation.

#Requires -Version 7.4

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:passCount = 0
$script:failCount = 0

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

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$stepFile = Join-Path $repoRoot 'src/scripts/checks/check-steps/13-repo-policy-data.ps1'

# WHY: check-lib.ps1 sources step-runner.ps1 and defines the Write-* helpers the
# drift helper calls; it needs both variables set before it is dot-sourced.
$RepoRoot = $repoRoot
$FrameworkDir = Join-Path $repoRoot 'src/scripts/lib'
# WHY: check-lib.ps1 reads $FrameworkDir to locate src/scripts/lib. PSSA cannot
# see a read that happens through dot-sourcing, so reference the variable here.
$null = $FrameworkDir  # check-suppress:suppression_doc: cross-scope read by dot-sourced check-lib.ps1; PSSA cannot track it
. (Join-Path $repoRoot 'src/scripts/checks/check-lib.ps1')
. $stepFile

if (-not (Get-Command Invoke-ProvisionedToolsInstructionDriftCheck -ErrorAction SilentlyContinue)) {
  Write-Output 'FAIL helper exists : Invoke-ProvisionedToolsInstructionDriftCheck not found after dot-sourcing'
  Write-Output "TOTAL $script:passCount passed, 1 failed"
  exit 1
}

function New-FixtureRepo {
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-provisioned-tools-drift-ps-" + [System.Guid]::NewGuid().ToString('N'))
  $null = New-Item -ItemType Directory -Path (Join-Path $root 'src/modules') -Force # check-suppress:suppression_doc: suppress fixture directory-creation output
  $null = New-Item -ItemType Directory -Path (Join-Path $root 'src/modules/packages') -Force # check-suppress:suppression_doc: suppress fixture directory-creation output
  $null = New-Item -ItemType Directory -Path (Join-Path $root 'src/users/default/agents/instructions') -Force # check-suppress:suppression_doc: suppress fixture directory-creation output
  return $root
}

function Write-CoreNix {
  param([string]$Root)
  $content = @'
  managedPackages = {
    default = {
      category = "cli";
    };
    keep-cli = {
      category = "cli";
    };
    gui-app = {
      category = "gui";
    };
    inter = {
      category = "cli";
    };
  };

  packageConfig = {
  };
'@
  Set-Content -LiteralPath (Join-Path $Root 'src/modules/core.nix') -Value $content -NoNewline
}

function Write-DesiredJson {
  param([string]$Root)
  $content = @'
{
  "$schema": "x",
  "bun": {
    "global": [
      { "name": "desired-tool" }
    ]
  }
}
'@
  Set-Content -LiteralPath (Join-Path $Root 'src/modules/packages/desired.json') -Value $content -NoNewline
}

function Write-Instruction {
  param([string]$Root, [string]$Body)
  Set-Content -LiteralPath (Join-Path $Root 'src/users/default/agents/instructions/nucleus-provisioned-tools.instructions.md') -Value $Body -NoNewline
}

function Invoke-Drift {
  param([string]$Root)
  $out = & {
    $ok = $false
    try {
      Invoke-ProvisionedToolsInstructionDriftCheck -RepoRoot $Root -Passed ([ref]$ok)
      [pscustomobject]@{ Ok = [bool]$ok }
    } catch {
      [pscustomobject]@{ Ok = $false; Threw = $true; Message = $_.Exception.Message }
    }
  } 2>&1
  $meta = @($out | Where-Object { $_ -is [pscustomobject] -and $null -ne $_.PSObject.Properties['Ok'] } | Select-Object -Last 1)
  $text = ($out | Where-Object { -not ($_ -is [pscustomobject] -and $null -ne $_.PSObject.Properties['Ok']) } | Out-String)
  if ($meta.Count -eq 0) {
    return [pscustomobject]@{ Ok = $false; Output = $text; Threw = $true }
  }
  $threw = $false
  if ($null -ne $meta[0].PSObject.Properties['Threw']) { $threw = [bool]$meta[0].Threw }
  return [pscustomobject]@{ Ok = [bool]$meta[0].Ok; Output = $text; Threw = $threw }
}

# 1. Pass: required managed CLI + desired present; gui/font/default excluded.
$root = New-FixtureRepo
try {
  Write-CoreNix -Root $root
  Write-DesiredJson -Root $root
  Write-Instruction -Root $root -Body 'Tools: `keep-cli` and `desired-tool`.'
  $r = Invoke-Drift -Root $root
  if ($r.Ok -and $r.Output -match 'provisioned tools instruction drift policy passed') {
    Assert-Pass 'required managed CLI and desired names pass; gui, font, and default are excluded'
  } else {
    Assert-Fail 'required managed CLI and desired names pass; gui, font, and default are excluded' "ok=$($r.Ok) output=[$($r.Output)]"
  }
} finally {
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# 2. Missing managedPackages CLI name fails and names it.
$root = New-FixtureRepo
try {
  Write-CoreNix -Root $root
  Write-DesiredJson -Root $root
  Write-Instruction -Root $root -Body 'Tools: `desired-tool` only.'
  $r = Invoke-Drift -Root $root
  if ((-not $r.Ok) -and $r.Output -match 'missing required tool name' -and $r.Output -match 'keep-cli') {
    Assert-Pass 'a missing managedPackages CLI name fails and names the tool'
  } else {
    Assert-Fail 'a missing managedPackages CLI name fails and names the tool' "ok=$($r.Ok) output=[$($r.Output)]"
  }
} finally {
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# 3. Missing desired.json name fails and names it.
$root = New-FixtureRepo
try {
  Write-CoreNix -Root $root
  Write-DesiredJson -Root $root
  Write-Instruction -Root $root -Body 'Tools: `keep-cli` only.'
  $r = Invoke-Drift -Root $root
  if ((-not $r.Ok) -and $r.Output -match 'missing required tool name' -and $r.Output -match 'desired-tool') {
    Assert-Pass 'a missing desired.json name fails and names the tool'
  } else {
    Assert-Fail 'a missing desired.json name fails and names the tool' "ok=$($r.Ok) output=[$($r.Output)]"
  }
} finally {
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# 4. Missing instruction fails.
$root = New-FixtureRepo
try {
  Write-CoreNix -Root $root
  Write-DesiredJson -Root $root
  $r = Invoke-Drift -Root $root
  if ((-not $r.Ok) -and $r.Output -match 'instruction not found') {
    Assert-Pass 'a missing instruction file fails'
  } else {
    Assert-Fail 'a missing instruction file fails' "ok=$($r.Ok) output=[$($r.Output)]"
  }
} finally {
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# 5. Step action wires the extracted helper (parity/registration evidence).
$stepSource = Get-Content -LiteralPath $stepFile -Raw
if ($stepSource -match 'Invoke-ProvisionedToolsInstructionDriftCheck\s+-RepoRoot' -and $stepSource -match '-Passed\s+\(\[ref\]' -and $stepSource -match 'function Invoke-ProvisionedToolsInstructionDriftCheck') {
  Assert-Pass 'the step action calls the extracted drift helper'
} else {
  Assert-Fail 'the step action calls the extracted drift helper' 'helper definition or call not found in step file'
}

Write-Output ''
Write-Output "TOTAL $script:passCount passed, $script:failCount failed"
if ($script:failCount -gt 0) { exit 1 }
exit 0
