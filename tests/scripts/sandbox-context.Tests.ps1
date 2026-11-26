#Requires -Version 7.0

<#
.SYNOPSIS
  Pester coverage for the `sandbox-context` helpers in scripts/utils.ps1.

.DESCRIPTION
  Verifies the PowerShell twin's record format, state decisions, output formats,
  pruning, corrupt-record handling, and config gate by running the real script
  in isolated subprocesses.

.NOTES
  Run with:
    pwsh -NoProfile -Command "Invoke-Pester tests/scripts/sandbox-context.Tests.ps1 -Output Detailed"
#>

BeforeAll {
  $script:RepoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')).Path
  $script:UtilsPs1 = Join-Path -Path $script:RepoRoot -ChildPath 'scripts/utils.ps1'
  $script:PwshPath = [Environment]::ProcessPath

  $script:SandboxedBlock = 'You are inside the srt sandbox. The repo and the granted scratch paths work normally, but the fence is real: network destinations and Unix sockets are allowlisted, some paths are read-only, git config hooks and secrets are protected, and deletions land in the Trash through the safe wrapper (Finder ''Put Back'' is unavailable because Apple Events are denied). If a command fails with a permission or socket error, assume the fence before assuming a bug, say what you need, and use `pi-unrestricted` only when the task genuinely needs the unsandboxed host.'
  $script:UnsandboxedBlock = 'You are outside the srt sandbox, so the full host is reachable. That is more power than the sandboxed default, so treat deletions, secrets, and network calls with extra care; the safe-delete rules still apply, and a command that worked here may be blocked in the sandbox when you switch back.'

  function New-SandboxContextHome {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param()

    $testHome = Join-Path -Path ([System.IO.Path]::GetTempPath()) ("nucleus-sctx-" + [guid]::NewGuid().ToString('N'))
    if (-not $PSCmdlet.ShouldProcess($testHome, 'create sandbox-context test home')) {
      return $testHome
    }
    $null = New-Item -ItemType Directory -Path $testHome -Force
    $null = New-Item -ItemType Directory -Path (Join-Path -Path $testHome -ChildPath '.local/state/nucleus') -Force
    if ($IsMacOS) {
      $null = New-Item -ItemType Directory -Path (Join-Path -Path $testHome -ChildPath 'Library/Application Support/nucleus') -Force
    } elseif ($IsWindows) {
      $null = New-Item -ItemType Directory -Path (Join-Path -Path $testHome -ChildPath 'AppData/Local/nucleus') -Force
    } else {
      $null = New-Item -ItemType Directory -Path (Join-Path -Path $testHome -ChildPath '.local/share/nucleus') -Force
    }
    return $testHome
  }

  function Remove-SandboxContextHome {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][string]$HomePath)

    if (Test-Path -LiteralPath $HomePath) {
      if (-not $PSCmdlet.ShouldProcess($HomePath, 'remove sandbox-context test home')) { return }
      Remove-Item -LiteralPath $HomePath -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  function Get-SandboxContextUserRoot {
    param([string]$HomePath)
    if ($IsMacOS) {
      return (Join-Path -Path $HomePath -ChildPath 'Library/Application Support/nucleus')
    }
    if ($IsWindows) {
      $local = Join-Path -Path $HomePath -ChildPath 'AppData/Local'
      return (Join-Path -Path $local -ChildPath 'nucleus')
    }
    return (Join-Path -Path $HomePath -ChildPath '.local/share/nucleus')
  }

  function Get-SandboxContextRecordFile {
    param([string]$HomePath, [string]$Harness)
    return (Join-Path -Path (Join-Path -Path (Join-Path -Path (Get-SandboxContextUserRoot -HomePath $HomePath) -ChildPath 'state') -ChildPath 'harness-bridge') -ChildPath "sandbox/$Harness.json")
  }

  function Invoke-SandboxContextScript {
    param(
      [Parameter(Mandatory)]
      [string]$HomePath,
      [Parameter(Mandatory)]
      [AllowEmptyString()]
      [string]$SandboxRuntimeValue,
      [Parameter(Mandatory)]
      [bool]$SandboxRuntimeSet,
      [Parameter(Mandatory)]
      [string[]]$Arguments,
      [AllowEmptyString()]
      [string]$StdinText = ''
    )

    $oldEnvHome = $env:HOME
    $oldLocalAppData = $env:LOCALAPPDATA
    $oldSandbox = $env:SANDBOX_RUNTIME
    $oldSandboxSet = [Environment]::GetEnvironmentVariables().Contains('SANDBOX_RUNTIME')
    try {
      $env:HOME = $HomePath
      if ($IsWindows) {
        $env:LOCALAPPDATA = Join-Path -Path $HomePath -ChildPath 'AppData/Local'
      } else {
        # Keep LOCALAPPDATA harmless on non-Windows hosts.
        $env:LOCALAPPDATA = $oldLocalAppData
      }
      if ($SandboxRuntimeSet) {
        $env:SANDBOX_RUNTIME = $SandboxRuntimeValue
      } else {
        Remove-Item Env:SANDBOX_RUNTIME -ErrorAction SilentlyContinue
      }

      $stdoutFile = [System.IO.Path]::GetTempFileName()
      $stderrFile = [System.IO.Path]::GetTempFileName()
      $stdinFile = $null
      try {
        $argList = @('-NoProfile', '-File', $script:UtilsPs1, 'sandbox-context') + $Arguments
        # Start-Process array arguments can mishandle paths with spaces on Unix;
        # pass a single quoted argument string.
        $argString = ($argList | ForEach-Object {
          $s = [string]$_
          if ($s -match '[\s"\\]') { '"' + ($s -replace '\\', '\\' -replace '"', '\"') + '"' } else { $s }
        }) -join ' '
        if ($StdinText -ne '') {
          $stdinFile = [System.IO.Path]::GetTempFileName()
          [System.IO.File]::WriteAllText($stdinFile, $StdinText, [System.Text.UTF8Encoding]::new($false))
          $proc = Start-Process -FilePath $script:PwshPath -ArgumentList $argString -RedirectStandardInput $stdinFile -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile -Wait -PassThru -NoNewWindow
        } else {
          $proc = Start-Process -FilePath $script:PwshPath -ArgumentList $argString -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile -Wait -PassThru -NoNewWindow
        }
        $stdout = if (Test-Path -LiteralPath $stdoutFile) { Get-Content -LiteralPath $stdoutFile -Raw -Encoding UTF8 } else { '' }
        $stderr = if (Test-Path -LiteralPath $stderrFile) { Get-Content -LiteralPath $stderrFile -Raw -Encoding UTF8 } else { '' }
        return [pscustomobject]@{ ExitCode = $proc.ExitCode; Stdout = ($stdout ?? ''); Stderr = ($stderr ?? '') }
      } finally {
        Remove-Item -LiteralPath $stdoutFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
        if ($null -ne $stdinFile) { Remove-Item -LiteralPath $stdinFile -Force -ErrorAction SilentlyContinue }
      }
    } finally {
      $env:HOME = $oldEnvHome
      $env:LOCALAPPDATA = $oldLocalAppData
      if ($oldSandboxSet) {
        $env:SANDBOX_RUNTIME = $oldSandbox
      } else {
        Remove-Item Env:SANDBOX_RUNTIME -ErrorAction SilentlyContinue
      }
    }
  }

  function Set-SandboxContextConfig {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
      [Parameter(Mandatory)][string]$HomePath,
      [Parameter(Mandatory)][hashtable]$Config
    )
    $path = Join-Path -Path $HomePath -ChildPath '.local/state/nucleus/config.json'
    if (-not $PSCmdlet.ShouldProcess($path, 'write sandbox-context test config')) { return }
    $json = ConvertTo-Json -InputObject $Config -Compress -Depth 10
    [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
  }

  function Get-SandboxContextRecord {
    param([string]$HomePath, [string]$Harness)
    $path = Get-SandboxContextRecordFile -HomePath $HomePath -Harness $Harness
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable)
  }
}

Describe 'nucleus-utils harness report-sandbox (PowerShell)' {
  It 'emits full sandboxed block and records state on first observation' {
    $testHome = New-SandboxContextHome
    try {
      $result = Invoke-SandboxContextScript -HomePath $testHome -SandboxRuntimeSet $true -SandboxRuntimeValue '1' -Arguments @('pi', '--format', 'text', '--session-id', 's1')
      $record = Get-SandboxContextRecord -HomePath $testHome -Harness 'pi'
      $result.ExitCode | Should -Be 0
      $result.Stdout.TrimEnd() | Should -Be $script:SandboxedBlock
      $record.sessions.s1.state | Should -Be 'sandboxed'
    } finally {
      Remove-SandboxContextHome -HomePath $testHome
    }
  }

  It 'emits a change notice naming both states and consequence on transition' {
    $testHome = New-SandboxContextHome
    try {
      $null = Invoke-SandboxContextScript -HomePath $testHome -SandboxRuntimeSet $true -SandboxRuntimeValue '1' -Arguments @('pi', '--format', 'text', '--session-id', 's1')
      $result = Invoke-SandboxContextScript -HomePath $testHome -SandboxRuntimeSet $false -SandboxRuntimeValue '' -Arguments @('pi', '--format', 'text', '--session-id', 's1')
      $result.ExitCode | Should -Be 0
      $result.Stdout | Should -Match 'Sandbox state changed: sandboxed -> unsandboxed\.'
      $result.Stdout | Should -Match 'full host is reachable'
    } finally {
      Remove-SandboxContextHome -HomePath $testHome
    }
  }

  It 'emits nothing and does not rewrite the record when unchanged' {
    $testHome = New-SandboxContextHome
    try {
      $null = Invoke-SandboxContextScript -HomePath $testHome -SandboxRuntimeSet $true -SandboxRuntimeValue '1' -Arguments @('pi', '--format', 'text', '--session-id', 's1')
      $path = Get-SandboxContextRecordFile -HomePath $testHome -Harness 'pi'
      $before = Get-Content -LiteralPath $path -Raw -Encoding UTF8
      $result = Invoke-SandboxContextScript -HomePath $testHome -SandboxRuntimeSet $true -SandboxRuntimeValue '1' -Arguments @('pi', '--format', 'text', '--session-id', 's1')
      $after = Get-Content -LiteralPath $path -Raw -Encoding UTF8
      $result.ExitCode | Should -Be 0
      $result.Stdout | Should -BeNullOrEmpty
      $after | Should -Be $before
    } finally {
      Remove-SandboxContextHome -HomePath $testHome
    }
  }

  It 'reports a corrupt record, treats it as unknown, and writes a valid observation' {
    $testHome = New-SandboxContextHome
    try {
      $path = Get-SandboxContextRecordFile -HomePath $testHome -Harness 'pi'
      $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
      [System.IO.File]::WriteAllText($path, '{not json', [System.Text.UTF8Encoding]::new($false))
      $result = Invoke-SandboxContextScript -HomePath $testHome -SandboxRuntimeSet $true -SandboxRuntimeValue '1' -Arguments @('pi', '--format', 'text', '--session-id', 's1')
      $record = Get-SandboxContextRecord -HomePath $testHome -Harness 'pi'
      $result.ExitCode | Should -Be 0
      $result.Stderr | Should -Match 'corrupt|unreadable'
      $result.Stdout.TrimEnd() | Should -Be $script:SandboxedBlock
      $record.sessions.s1.state | Should -Be 'sandboxed'
    } finally {
      Remove-SandboxContextHome -HomePath $testHome
    }
  }

  It 'prunes sessions unobserved for 30 days and caps the map at 50' {
    $testHome = New-SandboxContextHome
    try {
      $path = Get-SandboxContextRecordFile -HomePath $testHome -Harness 'pi'
      $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
      $old = (Get-Date).ToUniversalTime().AddDays(-40).ToString('yyyy-MM-ddTHH:mm:ssZ')
      $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
      $sessions = @{ 'old-session' = @{ state = 'sandboxed'; evidence = 'e'; observedAt = $old } }
      for ($i = 0; $i -lt 60; $i++) {
        $sessions[('s{0:00}' -f $i)] = @{ state = 'sandboxed'; evidence = 'e'; observedAt = $now }
      }
      $json = ConvertTo-Json -InputObject @{ version = 1; sessions = $sessions } -Compress -Depth 10
      [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))

      $result = Invoke-SandboxContextScript -HomePath $testHome -SandboxRuntimeSet $true -SandboxRuntimeValue '1' -Arguments @('pi', '--format', 'text', '--session-id', 'new-session')
      $record = Get-SandboxContextRecord -HomePath $testHome -Harness 'pi'
      $result.ExitCode | Should -Be 0
      $result.Stdout.TrimEnd() | Should -Be $script:SandboxedBlock
      $record.sessions.Count | Should -BeLessOrEqual 50
      $record.sessions.ContainsKey('old-session') | Should -BeFalse
      $record.sessions['new-session'].state | Should -Be 'sandboxed'
    } finally {
      Remove-SandboxContextHome -HomePath $testHome
    }
  }

  It 'records state advances without emitting when the gate is disabled' {
    $testHome = New-SandboxContextHome
    try {
      Set-SandboxContextConfig -HomePath $testHome -Config @{ 'sandbox-context' = @{ 'inject-on-change' = $false } }
      $first = Invoke-SandboxContextScript -HomePath $testHome -SandboxRuntimeSet $true -SandboxRuntimeValue '1' -Arguments @('pi', '--format', 'text', '--session-id', 's1')
      $path = Get-SandboxContextRecordFile -HomePath $testHome -Harness 'pi'
      $before = Get-Content -LiteralPath $path -Raw -Encoding UTF8
      $second = Invoke-SandboxContextScript -HomePath $testHome -SandboxRuntimeSet $false -SandboxRuntimeValue '' -Arguments @('pi', '--format', 'text', '--session-id', 's1')
      $record = Get-SandboxContextRecord -HomePath $testHome -Harness 'pi'
      $after = Get-Content -LiteralPath $path -Raw -Encoding UTF8

      $first.ExitCode | Should -Be 0
      $first.Stdout | Should -BeNullOrEmpty
      $second.ExitCode | Should -Be 0
      $second.Stdout | Should -BeNullOrEmpty
      $record.sessions.s1.state | Should -Be 'unsandboxed'
      $after | Should -Not -Be $before
    } finally {
      Remove-SandboxContextHome -HomePath $testHome
    }
  }

  It 'emits claude hook format and extracts session id from payload' {
    $testHome = New-SandboxContextHome
    try {
      $claude = Invoke-SandboxContextScript -HomePath $testHome -SandboxRuntimeSet $true -SandboxRuntimeValue '1' -Arguments @('claude', '--format', 'claude', '--session-id', 's1')
      $doc = $claude.Stdout | ConvertFrom-Json -AsHashtable
      $claude.ExitCode | Should -Be 0
      $doc.hookSpecificOutput.hookEventName | Should -Be 'UserPromptSubmit'
      $doc.hookSpecificOutput.additionalContext | Should -Match 'inside the srt sandbox'

      $check = Invoke-SandboxContextScript -HomePath $testHome -SandboxRuntimeSet $true -SandboxRuntimeValue '1' -Arguments @('claude', '--format', 'check') -StdinText '{"session_id":"sess-123","prompt":"hi"}'
      $record = Get-SandboxContextRecord -HomePath $testHome -Harness 'claude'
      $check.ExitCode | Should -Be 0
      $check.Stdout | Should -BeNullOrEmpty
      $record.sessions.ContainsKey('sess-123') | Should -BeTrue
    } finally {
      Remove-SandboxContextHome -HomePath $testHome
    }
  }
}
