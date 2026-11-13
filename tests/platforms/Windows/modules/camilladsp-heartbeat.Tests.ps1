<#
.SYNOPSIS
  Windows CamillaDSP heartbeat probe and warning formatting.
.DESCRIPTION
  Verifies the heartbeat probe reports the six device-selection fields and exits
  1 when no target can be bound, and that heartbeat warnings carry the local
  ISO-like timestamp prefix.
#>

Describe 'Windows CamillaDSP heartbeat' {
  BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..')).Path
    $script:heartbeatPath = Join-Path -Path $script:repoRoot -ChildPath 'src/scripts/services/camilladsp-heartbeat.ps1'
    $script:pwsh = Join-Path -Path $PSHOME -ChildPath 'pwsh'
    if ($IsWindows) { $script:pwsh = Join-Path -Path $PSHOME -ChildPath 'pwsh.exe' }
  }

  It 'probe prints six fields and exits 1 on a device null config with no bindable target' {
    $configPath = Join-Path -Path $TestDrive -ChildPath 'null-device.yml'
    Set-Content -LiteralPath $configPath -Value @'
devices:
  capture:
    type: Wasapi
    device: null
    loopback: true
  playback:
    type: Wasapi
    device: null
'@ -NoNewline

    $stateHome = Join-Path -Path $TestDrive -ChildPath 'xdg-state'
    $localAppData = Join-Path -Path $TestDrive -ChildPath 'localappdata'
    New-Item -ItemType Directory -Path $stateHome, $localAppData -Force > $null

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:pwsh
    foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $script:heartbeatPath, '-Probe', '-ConfigFile', $configPath)) {
      $psi.ArgumentList.Add($argument)
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.Environment['XDG_STATE_HOME'] = $stateHome
    $psi.Environment['LOCALAPPDATA'] = $localAppData
    $process = [System.Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    $lines = @($stdout -split "`r?`n" | Where-Object { $_ -match '^(platform|config|capture|default_output|available|target)=' })
    $names = @($lines | ForEach-Object { ($_ -split '=', 2)[0] })
    $names | Should -Be @('platform', 'config', 'capture', 'default_output', 'available', 'target')
    ($lines | Where-Object { $_ -like 'platform=*' }) | Should -Be @('platform=windows')
    ($lines | Where-Object { $_ -like "config=$configPath" }).Count | Should -Be 1
    ($lines | Where-Object { $_ -like 'target=*' }) | Should -Be @('target=')
    $process.ExitCode | Should -Be 1
    $combined = @($stdout, $stderr) -join "`n"
    ($combined -split "`r?`n" | Where-Object { $_ -match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d camilladsp-heartbeat: warning: probe found no playback device to bind' }).Count | Should -BeGreaterThan 0
  }

  It 'heartbeat warnings carry a local timestamp prefix' {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:heartbeatPath, [ref]$tokens, [ref]$parseErrors)
    $parseErrors.Count | Should -Be 0
    $definitions = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
    . ([scriptblock]::Create(($definitions | Where-Object { $_.Name -eq 'Write-CamillaDSPWarning' } | ForEach-Object { $_.Extent.Text }) -join "`n"))

    $scriptPath = Join-Path -Path $TestDrive -ChildPath 'warn.ps1'
    @'
param([string]$HeartbeatPath)
$ErrorActionPreference = "Stop"
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($HeartbeatPath, [ref]$tokens, [ref]$parseErrors)
$definitions = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
. ([scriptblock]::Create(($definitions | Where-Object { $_.Name -eq 'Write-CamillaDSPWarning' } | ForEach-Object { $_.Extent.Text }) -join "`n"))
Write-CamillaDSPWarning -Message 'example warning'
'@ | Set-Content -LiteralPath $scriptPath -NoNewline

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:pwsh
    foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $scriptPath, '-HeartbeatPath', $script:heartbeatPath)) {
      $psi.ArgumentList.Add($argument)
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($psi)
    $null = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    $process.ExitCode | Should -Be 0
    $stderr | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d camilladsp-heartbeat: warning: example warning'
  }
}
