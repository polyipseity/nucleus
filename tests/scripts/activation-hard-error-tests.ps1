#Requires -Version 7.4
# Tests asserting Windows activation modules hard-error when the child
# convergence script fails.  Sync-MenuBar / Sync-AppAutostart must abort
# (throw) on a failed convergence — no silent swallow of the child's exit code.
#
# Run with: pwsh -NoProfile tests/scripts/activation-hard-error-tests.ps1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:passCount = 0
$script:failCount = 0

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$formatModule = Join-Path $repoRoot 'src/platforms/Windows/modules/Format-NucleusOutput.psm1'
$syncMenuBar = Join-Path $repoRoot 'src/platforms/Windows/modules/user/Sync-MenuBar.ps1'
$syncAutostart = Join-Path $repoRoot 'src/platforms/Windows/modules/user/Sync-AppAutostart.ps1'
$installPrekHook = Join-Path $repoRoot 'src/platforms/Windows/modules/setup/Install-PrekHook.ps1'

Import-Module $formatModule -Force
. $syncMenuBar
. $syncAutostart
. $installPrekHook

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

# New-TempRepoWithFailingScript — Create a temp repo root whose
# src/scripts/<name> exits 1, so the Sync-* module's child invocation fails.
function New-TempRepoWithFailingScript {
  [CmdletBinding(SupportsShouldProcess)]
  [OutputType([string])]
  param([string]$ScriptName)
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-acthard-" + [guid]::NewGuid().ToString('N'))
  $dir = Join-Path -Path $root -ChildPath 'src' -AdditionalChildPath 'scripts'
  if ($PSCmdlet.ShouldProcess($dir, 'create a failing activation script')) {
    $null = New-Item -ItemType Directory -Path $dir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
    $null = Set-Content -Path (Join-Path $dir $ScriptName) -Value 'exit 1' -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
  }
  return $root
}

try {
  $menuBarRepo = New-TempRepoWithFailingScript -ScriptName 'menu-bar.ps1'
  $threw = $false
  try {
    Sync-MenuBar -Enabled -RepoRoot $menuBarRepo
  } catch {
    $threw = $true
  }
  if ($threw) {
    Assert-Pass 'Sync-MenuBar throws when child menu-bar.ps1 fails'
  } else {
    Assert-Fail 'Sync-MenuBar throws when child menu-bar.ps1 fails' 'returned without throwing'
  }

  $autostartRepo = New-TempRepoWithFailingScript -ScriptName 'autostart.ps1'
  $threw = $false
  try {
    Sync-AppAutostart -Enabled -RepoRoot $autostartRepo
  } catch {
    $threw = $true
  }
  if ($threw) {
    Assert-Pass 'Sync-AppAutostart throws when child autostart.ps1 fails'
  } else {
    Assert-Fail 'Sync-AppAutostart throws when' 'returned without throwing'
  }

  # Install-PrekHook must hard-error when prek cannot be resolved: a repository
  # that opts into prek must not silently lose its Git hooks.
  # WHY: the PATH is narrowed in a child process. Assigning $env:PATH in this
  # process would mutate the process environment, which sibling runspaces of the
  # parallel script-test runner (and the child scripts they launch) observe.
  $prekRepo = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-acthard-prek-" + [guid]::NewGuid().ToString('N'))
  $emptyPathDir = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-acthard-path-" + [guid]::NewGuid().ToString('N'))
  $driverScript = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-acthard-driver-" + [guid]::NewGuid().ToString('N') + '.ps1')
  $null = New-Item -ItemType Directory -Path $prekRepo -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
  $null = New-Item -ItemType Directory -Path $emptyPathDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
  $null = Set-Content -Path (Join-Path $prekRepo 'prek.toml') -Value 'fail_fast = true' -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
  # check-suppress:embedded-content: generated temp driver (data, not a template) that imports the module and exercises Install-PrekHook under a narrowed PATH
  $driverBody = @'
param([string]$ModulePath, [string]$HookPath, [string]$RepositoryRoot)
$ErrorActionPreference = 'Stop'
Import-Module $ModulePath -Force
. $HookPath
Install-PrekHook -RepositoryRoot $RepositoryRoot
'@
  $null = Set-Content -Path $driverScript -Value $driverBody -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup

  $pwshCommand = Get-Command -Name 'pwsh' -CommandType Application | Select-Object -First 1
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $pwshCommand.Source
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  foreach ($argument in @('-NoProfile', '-File', $driverScript, $formatModule, $installPrekHook, $prekRepo)) {
    $psi.ArgumentList.Add($argument)
  }
  $psi.Environment['PATH'] = $emptyPathDir

  $child = [System.Diagnostics.Process]::Start($psi)
  $childStdout = $child.StandardOutput.ReadToEndAsync()
  $childStderr = $child.StandardError.ReadToEndAsync()
  $child.WaitForExit()
  if ($child.ExitCode -ne 0) {
    Assert-Pass 'Install-PrekHook throws when prek cannot be resolved'
  } else {
    Assert-Fail 'Install-PrekHook throws when prek cannot be resolved' "child exited 0: $($childStdout.Result.Trim()) $($childStderr.Result.Trim())"
  }
} finally {
  foreach ($r in @($menuBarRepo, $autostartRepo, $prekRepo, $emptyPathDir, $driverScript)) {
    if ($r -and (Test-Path -LiteralPath $r)) {
      # check-suppress:suppression_doc: cleanup in test teardown -- failure is acceptable
      Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Write-Output ""
Write-Output "$script:passCount passed, $script:failCount failed"
if ($script:failCount -gt 0) { exit 1 }
exit 0
