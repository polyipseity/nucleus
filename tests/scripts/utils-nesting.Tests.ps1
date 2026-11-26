#Requires -Version 7.0

<#
.SYNOPSIS
  Pester coverage for nucleus-utils nested harness dispatch (Slice A, Task A1).
#>

BeforeAll {
  $script:RepoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')).Path
  $script:UtilsPs1 = Join-Path -Path $script:RepoRoot -ChildPath 'scripts/utils.ps1'
  $script:PwshPath = [Environment]::ProcessPath

  function New-UtilsTestHome {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param()
    $testHome = Join-Path -Path ([System.IO.Path]::GetTempPath()) ("nucleus-utils-" + [guid]::NewGuid().ToString('N'))
    if (-not $PSCmdlet.ShouldProcess($testHome, 'create utils test home')) { return $testHome }
    $null = New-Item -ItemType Directory -Path $testHome -Force
    $null = New-Item -ItemType Directory -Path (Join-Path -Path $testHome -ChildPath '.local/state/nucleus') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path -Path $testHome -ChildPath '.local/share/nucleus/state/harness-bridge') -Force
    return $testHome
  }

  function Remove-UtilsTestHome {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][string]$HomePath)
    if (Test-Path -LiteralPath $HomePath) {
      if (-not $PSCmdlet.ShouldProcess($HomePath, 'remove utils test home')) { return }
      Remove-Item -LiteralPath $HomePath -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  function Invoke-UtilsScript {
    param(
      [Parameter(Mandatory)][string]$HomePath,
      [Parameter(Mandatory)][string[]]$Arguments,
      [AllowEmptyString()][string]$StdinText = '',
      [hashtable]$ExtraEnv = @{}
    )

    $oldEnv = @{}
    foreach ($key in @('HOME', 'LOCALAPPDATA', 'SANDBOX_RUNTIME')) {
      $oldEnv[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
    }
    foreach ($key in $ExtraEnv.Keys) {
      $oldEnv[$key] = [Environment]::GetEnvironmentVariable([string]$key, 'Process')
    }
    try {
      Set-Item -Path Env:HOME -Value $HomePath -Force
      [Environment]::SetEnvironmentVariable('HOME', $HomePath, 'Process')
      if ($IsWindows) {
        $local = Join-Path -Path $HomePath -ChildPath 'AppData/Local'
        $null = New-Item -ItemType Directory -Path $local -Force
        Set-Item -Path Env:LOCALAPPDATA -Value $local -Force
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $local, 'Process')
      } else {
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $oldEnv['LOCALAPPDATA'], 'Process')
        if ($null -eq $oldEnv['LOCALAPPDATA']) { Remove-Item -Path Env:LOCALAPPDATA -ErrorAction SilentlyContinue } else { Set-Item -Path Env:LOCALAPPDATA -Value $oldEnv['LOCALAPPDATA'] -Force }
      }
      foreach ($key in $ExtraEnv.Keys) {
        [Environment]::SetEnvironmentVariable([string]$key, [string]$ExtraEnv[$key], 'Process')
        Set-Item -Path "Env:$key" -Value ([string]$ExtraEnv[$key]) -Force
      }

      $stdoutFile = [System.IO.Path]::GetTempFileName()
      $stderrFile = [System.IO.Path]::GetTempFileName()
      $stdinFile = $null
      try {
        $argList = @('-NoProfile', '-File', $script:UtilsPs1) + $Arguments
        $argString = ($argList | ForEach-Object {
          $s = [string]$_
          if ($s -match '[\s"\\]') { '"' + ($s -replace '\\', '\\' -replace '"', '\"') + '"' } else { $s }
        }) -join ' '
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $script:PwshPath
        $psi.Arguments = $argString
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = ($StdinText -ne '')
        foreach ($k in $psi.Environment.Keys) { } # enumerate to avoid modification issues
        $psi.Environment['HOME'] = $HomePath
        if ($IsWindows) { $psi.Environment['LOCALAPPDATA'] = (Join-Path -Path $HomePath -ChildPath 'AppData/Local') }
        foreach ($key in $ExtraEnv.Keys) { $psi.Environment[[string]$key] = [string]$ExtraEnv[$key] }
        $proc = [System.Diagnostics.Process]::new()
        $proc.StartInfo = $psi
        $null = $proc.Start()
        if ($StdinText -ne '') { $proc.StandardInput.Write($StdinText); $proc.StandardInput.Close() }
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        [System.IO.File]::WriteAllText($stdoutFile, $stdout, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText($stderrFile, $stderr, [System.Text.UTF8Encoding]::new($false))
        return [pscustomobject]@{ ExitCode = $proc.ExitCode; Stdout = ($stdout ?? ''); Stderr = ($stderr ?? '') }
      } finally {
        Remove-Item -LiteralPath $stdoutFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
        if ($null -ne $stdinFile) { Remove-Item -LiteralPath $stdinFile -Force -ErrorAction SilentlyContinue }
      }
    } finally {
      foreach ($key in $oldEnv.Keys) {
        $value = $oldEnv[$key]
        if ($key -eq 'HOME') {
          if ($null -ne $value) {
            Set-Item -Path Env:HOME -Value $value -Force
            [Environment]::SetEnvironmentVariable('HOME', $value, 'Process')
          }
          continue
        }
        [Environment]::SetEnvironmentVariable([string]$key, $value, 'Process')
        if ($null -eq $value) { Remove-Item -Path "Env:$key" -ErrorAction SilentlyContinue } else { Set-Item -Path "Env:$key" -Value $value }
      }
    }
  }
}

Describe 'nucleus-utils harness nesting (PowerShell)' {
  It 'lists verbs for bare harness and exits 0' {
    $testHome = New-UtilsTestHome
    try {
      $result = Invoke-UtilsScript -HomePath $testHome -Arguments @('harness')
      $result.ExitCode | Should -Be 0
      $result.Stdout | Should -Match 'send-notification'
      $result.Stdout | Should -Match 'merge-models'
    } finally { Remove-UtilsTestHome -HomePath $testHome }
  }

  It 'lists verbs for harness --help and exits 0' {
    $testHome = New-UtilsTestHome
    try {
      $result = Invoke-UtilsScript -HomePath $testHome -Arguments @('harness', '--help')
      $result.ExitCode | Should -Be 0
      $result.Stdout | Should -Match 'report-sandbox'
    } finally { Remove-UtilsTestHome -HomePath $testHome }
  }

  It 'fails clearly on unknown harness verb and lists valid verbs' {
    $testHome = New-UtilsTestHome
    try {
      $result = Invoke-UtilsScript -HomePath $testHome -Arguments @('harness', 'no-such-verb')
      $result.ExitCode | Should -Not -Be 0
      ($result.Stdout + $result.Stderr) | Should -Match 'unknown'
      ($result.Stdout + $result.Stderr) | Should -Match 'send-notification'
    } finally { Remove-UtilsTestHome -HomePath $testHome }
  }

  It 'routes report-sandbox to sandbox-context implementation' {
    $testHome = New-UtilsTestHome
    try {
      $result = Invoke-UtilsScript -HomePath $testHome -Arguments @('harness', 'report-sandbox', 'pi', '--format', 'text', '--session-id', 's1') -ExtraEnv @{ SANDBOX_RUNTIME = '1' }
      $result.ExitCode | Should -Be 0
      $record = Join-Path -Path $testHome -ChildPath '.local/share/nucleus/state/harness-bridge/sandbox/pi.json'
      if ($IsMacOS) { $record = Join-Path -Path $testHome -ChildPath 'Library/Application Support/nucleus/state/harness-bridge/sandbox/pi.json' }
      elseif ($IsWindows) { $record = Join-Path -Path $testHome -ChildPath 'AppData/Local/nucleus/state/harness-bridge/sandbox/pi.json' }
      Test-Path -LiteralPath $record | Should -BeTrue
    } finally { Remove-UtilsTestHome -HomePath $testHome }
  }

  It 'reports merge-models as not implemented' {
    $testHome = New-UtilsTestHome
    try {
      $result = Invoke-UtilsScript -HomePath $testHome -Arguments @('harness', 'merge-models', '--check')
      $result.ExitCode | Should -Not -Be 0
      ($result.Stdout + $result.Stderr) | Should -Match 'not implemented'
    } finally { Remove-UtilsTestHome -HomePath $testHome }
  }

  It 'keeps legacy top-level harness-notify alias dispatching during A1/A2 transition' {
    $testHome = New-UtilsTestHome
    try {
      $result = Invoke-UtilsScript -HomePath $testHome -Arguments @('harness-notify', 'pi', 'done', 'hello') -ExtraEnv @{ NUCLEUS_NOTIFY_DRY_RUN = '1' }
      $result.ExitCode | Should -Be 0
      ($result.Stdout + $result.Stderr) | Should -Not -Match 'unknown harness verb|is not recognized|Cannot validate argument'
    } finally { Remove-UtilsTestHome -HomePath $testHome }
  }

  It 'keeps legacy top-level harness-approval -Plain alias forwarding' {
    $testHome = New-UtilsTestHome
    try {
      $result = Invoke-UtilsScript -HomePath $testHome -Arguments @('harness-approval', '-Plain', 'pi', 'run_command', 'ls')
      $result.ExitCode | Should -Be 0
      $result.Stdout.Trim() | Should -Match '^(allow|deny|ask)$'
      ($result.Stdout + $result.Stderr) | Should -Not -Match 'Cannot process argument transformation|TimeoutSeconds'
    } finally { Remove-UtilsTestHome -HomePath $testHome }
  }
}
