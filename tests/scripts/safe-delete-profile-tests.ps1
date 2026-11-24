#Requires -Version 7.4
# Unit tests for Invoke-SafeDelete in src/scripts/shell/profile.ps1.
# Focus: a single string path must not be character-splatted when delegated.

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

# Dot-source profile in a clean child pwsh so its side effects do not leak.
# The child writes captured args to a log file, one per line.
function Invoke-ProfileProbe {
  param(
    [Parameter(Mandatory)][string]$Expression
  )

  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-safe-delete-test-" + [System.Guid]::NewGuid().ToString('N'))
  $null = New-Item -ItemType Directory -Path $tmp
  try {
    $log = Join-Path $tmp 'args.txt'
    $fake = Join-Path $tmp 'safe-rm'
    @'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "${NUCLEUS_SAFE_RM_LOG:?}"
'@ | Set-Content -Path $fake -Encoding utf8NoBOM
    & chmod +x $fake

    $child = @"
`$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
`$env:NUCLEUS_SAFE_RM_LOG = '$log'
`$env:PATH = '$tmp' + [System.IO.Path]::PathSeparator + `$env:PATH

# Extract only Invoke-SafeDelete from profile.ps1 to avoid top-level side effects.
`$tokens = `$null; `$errors = `$null
`$ast = [System.Management.Automation.Language.Parser]::ParseFile('$profilePath', [ref]`$tokens, [ref]`$errors)
if (`$errors.Count -gt 0) { throw (`$errors | ForEach-Object Message | Join-String -Separator '; ') }
`$fn = `$ast.FindAll({ param(`$n) `$n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and `$n.Name -eq 'Invoke-SafeDelete' }, `$true) | Select-Object -First 1
if (-not `$fn) { throw 'Invoke-SafeDelete not found in profile.ps1' }
. ([scriptblock]::Create(`$fn.Extent.Text))

$Expression
"@
    $childPath = Join-Path $tmp 'probe.ps1'
    Set-Content -Path $childPath -Value $child -Encoding utf8NoBOM

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Command pwsh).Source
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($a in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $childPath)) {
      $psi.ArgumentList.Add($a)
    }
    $p = [System.Diagnostics.Process]::Start($psi)
    $stdout = $p.StandardOutput.ReadToEndAsync()
    $stderr = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    $argsOut = if (Test-Path $log) { @((Get-Content -Path $log) | Where-Object { $_ -ne '' }) } else { @() }
    return [pscustomobject]@{
      ExitCode = $p.ExitCode
      Stdout   = $stdout.Result
      Stderr   = $stderr.Result
      Args     = [string[]]@($argsOut)
    }
  }
  finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Test-SinglePathNotCharSplatted {
  $r = Invoke-ProfileProbe -Expression 'Invoke-SafeDelete "ab"'
  if ($r.ExitCode -ne 0) {
    Assert-Fail 'single-path-not-char-splatted' "probe exited $($r.ExitCode): $($r.Stderr)"
    return
  }
  if (@($r.Args).Count -eq 1 -and $r.Args[0] -eq 'ab') {
    Assert-Pass 'single-path-not-char-splatted'
  } else {
    Assert-Fail 'single-path-not-char-splatted' "expected [ab], got [$($r.Args -join ', ')]"
  }
}

function Test-MultiplePathsPreserved {
  $r = Invoke-ProfileProbe -Expression 'Invoke-SafeDelete -Path @("ab","cd")'
  if ($r.ExitCode -ne 0) {
    Assert-Fail 'multiple-paths-preserved' "probe exited $($r.ExitCode): $($r.Stderr)"
    return
  }
  if (@($r.Args).Count -eq 2 -and $r.Args[0] -eq 'ab' -and $r.Args[1] -eq 'cd') {
    Assert-Pass 'multiple-paths-preserved'
  } else {
    Assert-Fail 'multiple-paths-preserved' "expected [ab, cd], got [$($r.Args -join ', ')]"
  }
}

function Test-LiteralPathSinglePath {
  $r = Invoke-ProfileProbe -Expression 'Invoke-SafeDelete -LiteralPath "ab"'
  if ($r.ExitCode -ne 0) {
    Assert-Fail 'literalpath-single-path' "probe exited $($r.ExitCode): $($r.Stderr)"
    return
  }
  if (@($r.Args).Count -eq 1 -and $r.Args[0] -eq 'ab') {
    Assert-Pass 'literalpath-single-path'
  } else {
    Assert-Fail 'literalpath-single-path' "expected [ab], got [$($r.Args -join ', ')]"
  }
}

function Test-RecurseForceStillBind {
  # Should not throw parameter-binding errors; safe-rm receives the path.
  $r = Invoke-ProfileProbe -Expression 'Invoke-SafeDelete -Recurse -Force "ab"'
  if ($r.ExitCode -ne 0) {
    Assert-Fail 'recurse-force-still-bind' "probe exited $($r.ExitCode): $($r.Stderr)"
    return
  }
  if (@($r.Args).Count -eq 1 -and $r.Args[0] -eq 'ab') {
    Assert-Pass 'recurse-force-still-bind'
  } else {
    Assert-Fail 'recurse-force-still-bind' "expected [ab], got [$($r.Args -join ', ')]"
  }
}

Write-Output "=== safe-delete-profile tests ==="
Test-SinglePathNotCharSplatted
Test-MultiplePathsPreserved
Test-LiteralPathSinglePath
Test-RecurseForceStillBind

Write-Output ""
Write-Output "safe-delete-profile: $($script:passCount) passed, $($script:failCount) failed"
if ($script:failCount -gt 0) { exit 1 }
exit 0
