#Requires -Version 7.0

<#
.SYNOPSIS
  Pester coverage for nucleus-utils nested harness dispatch (Slice A, Task A1).
#>

BeforeAll {
  $script:RepoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')).Path
  $script:UtilsPs1 = Join-Path -Path $script:RepoRoot -ChildPath 'scripts/utils.ps1'
  $script:PwshPath = [Environment]::ProcessPath
  . (Join-Path -Path $script:RepoRoot -ChildPath 'src/platforms/Windows/modules/ManagedPaths.ps1')

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

  function Set-UtilsTestConfig {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][string]$HomePath)
    $path = Join-Path -Path $HomePath -ChildPath '.local/state/nucleus/config.json'
    if (-not $PSCmdlet.ShouldProcess($path, 'write utils test config')) { return }
    $config = @{
      'harness-notify'   = @{ enable = $true }
      'harness-approval' = @{ sources = @() }
    }
    $json = ConvertTo-Json -InputObject $config -Compress -Depth 10
    [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
  }

  function New-FakeManagedHarnessPython {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$HomePath)
    $localAppData = Join-Path -Path $HomePath -ChildPath 'AppData/Local'
    $userRoot = Join-Path -Path $localAppData -ChildPath 'nucleus'
    $fakePython = Get-NucleusHarnessPythonExe -UserRoot $userRoot
    if (-not $PSCmdlet.ShouldProcess($fakePython, 'Create fake Python stub')) { return $fakePython }
    $null = New-Item -ItemType Directory -Path $localAppData -Force
    $null = New-Item -ItemType Directory -Path (Split-Path -Path $fakePython -Parent) -Force
    if ($IsWindows) {
      $typeName = 'FakeHarnessPython' + [guid]::NewGuid().ToString('N')
      $source = @"
using System;
using System.IO;
public static class $typeName
{
  public static void Main(string[] args)
  {
    string marker = Environment.GetEnvironmentVariable("NUCLEUS_TEST_PY_MARKER");
    if (!string.IsNullOrEmpty(marker))
    {
      File.AppendAllText(marker, "managed-python " + string.Join(" ", args) + "\n");
    }
  }
}
"@
      $null = Add-Type -TypeDefinition $source -OutputAssembly $fakePython -OutputType ConsoleApplication
    } else {
      $body = "#!/bin/sh`nprintf 'managed-python %s\n' `"`$*`" >> `"`$NUCLEUS_TEST_PY_MARKER`"`nexit 0`n"
      $null = Set-Content -LiteralPath $fakePython -Value $body -NoNewline
      [System.IO.File]::SetUnixFileMode($fakePython, [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite -bor [System.IO.UnixFileMode]::UserExecute)
    }
    return $fakePython
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

  It 'routes report-sandbox to report-sandbox implementation' {
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

  It 'seeds an isolated home with merge-models and passes --check' {
    $testHome = New-UtilsTestHome
    try {
      $null = New-Item -ItemType Directory -Path (Join-Path -Path $testHome -ChildPath '.pi/agent') -Force
      $target = Join-Path -Path $testHome -ChildPath '.pi/agent/models.json'
      $seed = Invoke-UtilsScript -HomePath $testHome -Arguments @(
        'harness', 'merge-models', '--home', $testHome, '--repo-root', $script:RepoRoot, '--harness', 'pi'
      )
      $seed.ExitCode | Should -Be 0
      Test-Path -LiteralPath $target -PathType Leaf | Should -BeTrue

      $actual = Get-Content -LiteralPath $target -Raw | ConvertFrom-Json -AsHashtable
      $payloadPath = Join-Path -Path $script:RepoRoot -ChildPath 'src/users/default/pi/litellm-models.json'
      $expected = Get-Content -LiteralPath $payloadPath -Raw | ConvertFrom-Json -AsHashtable
      ($actual['providers']['litellm'] | ConvertTo-Json -Depth 10 -Compress) |
        Should -Be ($expected | ConvertTo-Json -Depth 10 -Compress)

      $check = Invoke-UtilsScript -HomePath $testHome -Arguments @(
        'harness', 'merge-models', '--home', $testHome, '--repo-root', $script:RepoRoot, '--harness', 'pi', '--check'
      )
      $check.ExitCode | Should -Be 0
    } finally { Remove-UtilsTestHome -HomePath $testHome }
  }

  It 'fails --check after the isolated home config drifts' {
    $testHome = New-UtilsTestHome
    try {
      $null = New-Item -ItemType Directory -Path (Join-Path -Path $testHome -ChildPath '.pi/agent') -Force
      $target = Join-Path -Path $testHome -ChildPath '.pi/agent/models.json'
      $seed = Invoke-UtilsScript -HomePath $testHome -Arguments @(
        'harness', 'merge-models', '--home', $testHome, '--repo-root', $script:RepoRoot, '--harness', 'pi'
      )
      $seed.ExitCode | Should -Be 0
      $data = Get-Content -LiteralPath $target -Raw | ConvertFrom-Json -AsHashtable
      $data['providers']['litellm']['api'] = 'stale-api'
      [System.IO.File]::WriteAllText($target, ($data | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))

      $check = Invoke-UtilsScript -HomePath $testHome -Arguments @(
        'harness', 'merge-models', '--home', $testHome, '--repo-root', $script:RepoRoot, '--harness', 'pi', '--check'
      )
      $check.ExitCode | Should -Not -Be 0
    } finally { Remove-UtilsTestHome -HomePath $testHome }
  }

  It 'uses the managed harness Python for merge-models when the venv exists' {
    $testHome = New-UtilsTestHome
    try {
      $fakePython = New-FakeManagedHarnessPython -HomePath $testHome
      Test-Path -LiteralPath $fakePython -PathType Leaf | Should -BeTrue
      $marker = Join-Path -Path $testHome -ChildPath 'fake-python-invoked.log'
      $result = Invoke-UtilsScript -HomePath $testHome -Arguments @(
        'harness', 'merge-models', '--home', $testHome, '--repo-root', $script:RepoRoot, '--harness', 'pi'
      ) -ExtraEnv @{
        LOCALAPPDATA           = (Join-Path -Path $testHome -ChildPath 'AppData/Local')
        NUCLEUS_TEST_PY_MARKER = $marker
      }
      $result.ExitCode | Should -Be 0
      Test-Path -LiteralPath $marker -PathType Leaf | Should -BeTrue
      $markerText = (Get-Content -LiteralPath $marker -Raw).Trim()
      $markerText | Should -Match 'managed-python'
      $markerText | Should -Match 'merge-harness-models.py'
    } finally { Remove-UtilsTestHome -HomePath $testHome }
  }

  It 'executes the compiled Python stub directly on Windows' {
    if (-not $IsWindows) { Set-ItResult -Skipped -Because 'the compiled stub is built only on Windows' }
    $testHome = New-UtilsTestHome
    try {
      $fakePython = New-FakeManagedHarnessPython -HomePath $testHome
      $marker = Join-Path -Path $testHome -ChildPath 'direct-stub-invoked.log'
      $env:NUCLEUS_TEST_PY_MARKER = $marker
      try {
        & $fakePython '--repo-root', $script:RepoRoot, 'merge-harness-models.py'
        $LASTEXITCODE | Should -Be 0
      } finally {
        Remove-Item Env:NUCLEUS_TEST_PY_MARKER -ErrorAction SilentlyContinue # check-suppress:suppression_doc: restore the process environment after a Windows-only fixture
      }
      (Get-Content -LiteralPath $marker -Raw) | Should -Match 'merge-harness-models.py'
    } finally { Remove-UtilsTestHome -HomePath $testHome }
  }

  It 'forwards --command to check-deletion' {
    $testHome = New-UtilsTestHome
    try {
      Set-UtilsTestConfig -HomePath $testHome
      $deletionWord = 'r' + 'm'
      $commandText = "env -i $deletionWord -rf forwarding-probe"
      $result = Invoke-UtilsScript -HomePath $testHome -Arguments @('harness', 'check-deletion', '--command', $commandText)
      $result.ExitCode | Should -Be 0
      $result.Stdout | Should -Match '^ask\tunproven-redirect\tdeletion command: rm runs under env -i'
    } finally { Remove-UtilsTestHome -HomePath $testHome }
  }

  It 'forwards --settings and --command to check-deletion' {
    $testHome = New-UtilsTestHome
    try {
      Set-UtilsTestConfig -HomePath $testHome
      $deletionWord = 'r' + 'm'
      $commandText = "env -i $deletionWord -rf forwarding-settings"
      $result = Invoke-UtilsScript -HomePath $testHome -Arguments @('harness', 'check-deletion', '--settings', '{"unproven":"allow"}', '--command', $commandText)
      $result.ExitCode | Should -Be 0
      $result.Stdout | Should -Match '^allow\tunproven-redirect'
      $result.Stdout | Should -Match 'settings.unproven allows an unproven redirect'
    } finally { Remove-UtilsTestHome -HomePath $testHome }
  }

  It 'forwards --hook and stdin payload to check-deletion' {
    $testHome = New-UtilsTestHome
    try {
      Set-UtilsTestConfig -HomePath $testHome
      $nativeWord = '/bin/' + 'r' + 'm'
      $payload = '{"tool_input":{"command":"' + $nativeWord + ' forwarding-hook"}}'
      $result = Invoke-UtilsScript -HomePath $testHome -Arguments @('harness', 'check-deletion', '--hook') -StdinText $payload
      $result.ExitCode | Should -Be 2
      $result.Stderr | Should -Match 'BLOCKED: native rm bypasses safe-delete protection'
    } finally { Remove-UtilsTestHome -HomePath $testHome }
  }

  It 'forwards request-approval and returns its typed document' {
    $testHome = New-UtilsTestHome
    try {
      Set-UtilsTestConfig -HomePath $testHome
      $result = Invoke-UtilsScript -HomePath $testHome -Arguments @('harness', 'request-approval', 'cursor', 'shelltool', 'forwarding summary')
      $result.ExitCode | Should -Be 0
      $doc = $result.Stdout.Trim() | ConvertFrom-Json -AsHashtable
      $doc['version'] | Should -Be 1
      $doc['decision'] | Should -Be 'ask'
      $doc['reason'] | Should -Be 'no approval sources enabled'
      $doc['source'] | Should -Be 'none'
      $doc['timeouts']['hermes'] | Should -Be 300
      $doc['timeouts']['prompt'] | Should -Be 600
      @($doc['timedOutSources']).Count | Should -Be 0
      $result.Stderr | Should -Not -Match 'usage:'
    } finally { Remove-UtilsTestHome -HomePath $testHome }
  }

  It 'forwards --format to report-sandbox' {
    $testHome = New-UtilsTestHome
    try {
      Set-UtilsTestConfig -HomePath $testHome
      $result = Invoke-UtilsScript -HomePath $testHome -Arguments @('harness', 'report-sandbox', 'pi', '--format', 'claude', '--session-id', 'format-probe') -ExtraEnv @{ SANDBOX_RUNTIME = '1' }
      $result.ExitCode | Should -Be 0
      $doc = $result.Stdout | ConvertFrom-Json -AsHashtable
      $doc.hookSpecificOutput.hookEventName | Should -Be 'UserPromptSubmit'
      $record = Join-Path -Path $testHome -ChildPath '.local/share/nucleus/state/harness-bridge/sandbox/pi.json'
      if ($IsMacOS) { $record = Join-Path -Path $testHome -ChildPath 'Library/Application Support/nucleus/state/harness-bridge/sandbox/pi.json' }
      elseif ($IsWindows) { $record = Join-Path -Path $testHome -ChildPath 'AppData/Local/nucleus/state/harness-bridge/sandbox/pi.json' }
      (Get-Content -LiteralPath $record -Raw | ConvertFrom-Json -AsHashtable).sessions.ContainsKey('format-probe') | Should -BeTrue
    } finally { Remove-UtilsTestHome -HomePath $testHome }
  }

  It 'rejects every legacy top-level alias' {
    $testHome = New-UtilsTestHome
    try {
      foreach ($alias in @('harness-notify', 'harness-approval', 'harness-filter', 'harness-drive', 'sandbox-context', 'safe-delete-guard')) {
        $result = Invoke-UtilsScript -HomePath $testHome -Arguments @($alias)
        $result.ExitCode | Should -Not -Be 0
        ($result.Stdout + $result.Stderr) | Should -Match 'unknown subcommand|Cannot validate argument|not a valid value for the Action variable'
      }
    } finally { Remove-UtilsTestHome -HomePath $testHome }
  }
}
