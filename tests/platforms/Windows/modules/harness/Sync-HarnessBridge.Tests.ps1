<#
.SYNOPSIS
  Pester coverage for the Windows harness-bridge twins and their PATH shims.

.DESCRIPTION
  Covers the two deployed hook entry points (hook-mode rendering per harness,
  remote decision flow, fail-open exit codes) and the shim convergence performed
  by Sync-HarnessBridge.ps1.

  The entry points run as child processes with HOME, USERPROFILE, LOCALAPPDATA,
  and PATH pointed at a sandbox, so the real user configuration and the real
  nucleus state directory are never touched.  A stub `hermes` on PATH records
  what each notification asked for, which is how channel fan-out, subject, and
  body are asserted.

.NOTES
  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/harness/Sync-HarnessBridge.Tests.ps1 -Output Detailed"

  Environment variables: none read from the test process; HOME, USERPROFILE,
  LOCALAPPDATA, PATH, and HERMES_STUB_LOG are set for the child processes only.

  Exit codes: 0 on success; 1 on failure.
#>

BeforeAll {
  $script:RepoRootPath = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..')).Path
  $script:NotifyDir = Join-Path -Path $script:RepoRootPath -ChildPath 'src\scripts\notify'

  function New-HarnessBridgeSandbox {
    <#
    .SYNOPSIS
      Creates an isolated repository/user-root sandbox for one test.
    .DESCRIPTION
      The "repository" holds copies of the two real entry points so the deployment
      logic exercises real content, while HOME/LOCALAPPDATA/PATH point at empty
      directories the test owns.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([hashtable])]
    param()

    $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) ("nucleus-hbridge-" + [guid]::NewGuid().ToString('N'))
    $sandbox = @{
      Root      = $root
      Repo      = Join-Path -Path $root 'repo'
      Home      = Join-Path -Path $root 'home'
      LocalApp  = Join-Path -Path $root 'localappdata'
      StubDir   = Join-Path -Path $root 'stubbin'
      HermesLog = Join-Path -Path $root 'hermes.log'
    }

    foreach ($dir in @($sandbox.Repo, $sandbox.Home, $sandbox.LocalApp, $sandbox.StubDir)) {
      $null = New-Item -ItemType Directory -Path $dir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
    }

    $sourceDir = Join-Path -Path $sandbox.Repo -ChildPath 'src\scripts\notify'
    $null = New-Item -ItemType Directory -Path $sourceDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
    foreach ($name in @('harness-approval', 'harness-notify')) {
      Copy-Item -LiteralPath (Join-Path -Path $script:NotifyDir -ChildPath "$name.ps1") -Destination (Join-Path -Path $sourceDir -ChildPath "$name.ps1")
    }

    $null = Set-Content -Path $sandbox.HermesLog -Value '' -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
    return $sandbox
  }

  function Remove-HarnessBridgeSandbox {
    <#
    .SYNOPSIS
      Deletes a sandbox created by New-HarnessBridgeSandbox.
    .PARAMETER Root
      Sandbox root directory.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
      [Parameter(Mandatory)]
      [string]$Root
    )

    if (Test-Path -LiteralPath $Root) {
      # check-suppress:suppression_doc: cleanup in test teardown -- failure is acceptable
      Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  function Write-HermesStub {
    <#
    .SYNOPSIS
      Writes recording `hermes` stubs into a sandbox stub directory.
    .DESCRIPTION
      Both platform spellings are written: a POSIX `hermes` script (resolved
      through the executable bit) and a Windows `hermes.cmd` (resolved through
      PATHEXT) that forwards stdin to a PowerShell reader.  Each records
      `ARGV <arguments>` and `BODY <stdin>` lines in the sandbox log.
    .PARAMETER StubDir
      Directory to write the stubs into.
    #>
    [CmdletBinding()]
    param(
      [Parameter(Mandatory)]
      [string]$StubDir
    )

    $posixStub = Join-Path -Path $StubDir -ChildPath 'hermes'
    $posixBody = @(
      '#!/usr/bin/env bash'
      '{'
      '  printf ARGV'
      '  for _arg in "$@"; do printf " %s" "$_arg"; done'
      '  printf "\n"'
      '} >>"$HERMES_STUB_LOG"'
      'printf "BODY %s\n" "$(cat)" >>"$HERMES_STUB_LOG"'
    ) -join "`n"
    $null = Set-Content -Path $posixStub -Value $posixBody -NoNewline -Encoding utf8  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup

    $readerPath = Join-Path -Path $StubDir -ChildPath 'hermes-stub.ps1'
    $readerBody = @(
      '$body = [Console]::In.ReadToEnd()'
      "Add-Content -LiteralPath `$env:HERMES_STUB_LOG -Value ('ARGV ' + (`$args -join ' ')) -Encoding utf8"
      "Add-Content -LiteralPath `$env:HERMES_STUB_LOG -Value ('BODY ' + `$body.Trim()) -Encoding utf8"
    ) -join "`n"
    $null = Set-Content -Path $readerPath -Value $readerBody -NoNewline -Encoding utf8  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup

    $cmdStub = Join-Path -Path $StubDir -ChildPath 'hermes.cmd'
    $null = Set-Content -Path $cmdStub -Value "@echo off`r`npwsh -NoProfile -File `"%~dp0hermes-stub.ps1`" %*`r`n" -NoNewline -Encoding ascii  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup


    if (-not $IsWindows) { & chmod +x $posixStub }
  }

  function Set-SandboxConfig {
    <#
    .SYNOPSIS
      Writes the sandbox runtime config file (~\.local\state\nucleus\config.json).
    .PARAMETER Sandbox
      Sandbox created by New-HarnessBridgeSandbox.
    .PARAMETER Config
      Config object to serialize.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
      [Parameter(Mandatory)]
      [hashtable]$Sandbox,

      [Parameter(Mandatory)]
      [hashtable]$Config
    )

    $configDir = Join-Path -Path $Sandbox.Home -ChildPath '.local/state/nucleus'
    $null = New-Item -ItemType Directory -Path $configDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
    $json = ConvertTo-Json -InputObject $Config -Compress -Depth 10
    [System.IO.File]::WriteAllText((Join-Path -Path $configDir -ChildPath 'config.json'), $json, [System.Text.UTF8Encoding]::new($false))
  }

  function Start-TwinProcess {
    <#
    .SYNOPSIS
      Starts one harness-bridge entry point as a child pwsh process.
    .PARAMETER Sandbox
      Sandbox supplying HOME, USERPROFILE, LOCALAPPDATA, and PATH.
    .PARAMETER ScriptPath
      Entry point to run.
    .PARAMETER Arguments
      Positional arguments for the entry point; empty for the usage-path tests.
    .PARAMETER Stdin
      Optional standard input (hook payload).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([hashtable])]
    param(
      [Parameter(Mandatory)]
      [hashtable]$Sandbox,

      [Parameter(Mandatory)]
      [string]$ScriptPath,

      [string[]]$Arguments = @(),

      [string]$Stdin = ''
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    # WHY: several pwsh wrappers can sit on PATH (nix profile, system, store);
    # ProcessStartInfo needs exactly one executable path.
    $psi.FileName = (Get-Command -Name 'pwsh' -CommandType Application | Select-Object -First 1).Source
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-File', $ScriptPath) + $Arguments) {
      $null = $psi.ArgumentList.Add($argument)  # check-suppress:suppression_doc: ArgumentList.Add returns void; the call is the side effect
    }

    $psi.Environment['HOME'] = $Sandbox.Home
    $psi.Environment['USERPROFILE'] = $Sandbox.Home
    $psi.Environment['LOCALAPPDATA'] = $Sandbox.LocalApp
    $psi.Environment['HERMES_STUB_LOG'] = $Sandbox.HermesLog
    $psi.Environment['PATH'] = $Sandbox.StubDir + [System.IO.Path]::PathSeparator + $env:PATH

    $process = [System.Diagnostics.Process]::Start($psi)
    $started = @{
      Process = $process
      Stdout  = $process.StandardOutput.ReadToEndAsync()
      Stderr  = $process.StandardError.ReadToEndAsync()
    }
    if ($Stdin) { $process.StandardInput.Write($Stdin) }
    $process.StandardInput.Close()
    return $started
  }

  function Wait-TwinProcess {
    <#
    .SYNOPSIS
      Waits for a started entry point and returns its exit code and streams.
    .PARAMETER Started
      Handle returned by Start-TwinProcess.
    .PARAMETER TimeoutSeconds
      Maximum wait before the child is killed.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
      [Parameter(Mandatory)]
      [hashtable]$Started,

      [int]$TimeoutSeconds = 30
    )

    if (-not $Started.Process.WaitForExit($TimeoutSeconds * 1000)) {
      $Started.Process.Kill()
      throw "entry point did not exit within $TimeoutSeconds s"
    }

    return @{
      ExitCode = $Started.Process.ExitCode
      Stdout   = $Started.Stdout.GetAwaiter().GetResult().Trim()
      Stderr   = $Started.Stderr.GetAwaiter().GetResult().Trim()
    }
  }

  function Get-HermesStubLog {
    <#
    .SYNOPSIS
      Reads the stub hermes log lines.
    .PARAMETER Sandbox
      Sandbox whose stub log should be read.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
      [Parameter(Mandatory)]
      [hashtable]$Sandbox
    )

    if (-not (Test-Path -LiteralPath $Sandbox.HermesLog)) { return [string[]]@() }
    return [string[]]@(Get-Content -LiteralPath $Sandbox.HermesLog -Encoding UTF8 | Where-Object { $_ -ne '' })
  }

  function Get-BridgeStateDir {
    <#
    .SYNOPSIS
      Resolves the sandbox harness-bridge state directory.
    .PARAMETER Sandbox
      Sandbox whose state directory should be resolved.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
      [Parameter(Mandatory)]
      [hashtable]$Sandbox
    )

    return (Join-Path -Path $Sandbox.LocalApp -ChildPath 'nucleus\state\harness-bridge')
  }
}

Describe 'Sync-HarnessBridge shim convergence' {
  BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\Format-NucleusOutput.psm1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\ManagedPaths.ps1')
    . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\user\Sync-HarnessBridge.ps1')

    $script:syncSandbox = New-HarnessBridgeSandbox
    $script:originalHome = $HOME
    Set-Variable -Name HOME -Value $script:syncSandbox.Home -Force
    $script:syncUserRoot = Join-Path -Path $script:syncSandbox.LocalApp -ChildPath 'nucleus'
    $script:syncShimDir = Join-Path -Path $script:syncSandbox.Home -ChildPath '.local\bin'
    $script:syncBinDir = Join-Path -Path $script:syncUserRoot -ChildPath 'bin'
  }

  AfterAll {
    Set-Variable -Name HOME -Value $script:originalHome -Force
    Remove-HarnessBridgeSandbox -Root $script:syncSandbox.Root
  }

  It 'deploys both entry points and both PATH shims on an enabled run' {
    Sync-HarnessBridge -Enabled:$true -RepoRoot $script:syncSandbox.Repo -UserRoot $script:syncUserRoot -UserProfile $script:syncSandbox.Home > $null

    foreach ($name in @('harness-approval', 'harness-notify')) {
      $deployed = Join-Path -Path $script:syncBinDir -ChildPath "$name.ps1"
      $source = Join-Path -Path $script:syncSandbox.Repo -ChildPath "src\scripts\notify\$name.ps1"
      Test-Path -LiteralPath $deployed | Should -Be $true
      (Get-Content -LiteralPath $deployed -Raw -Encoding UTF8) | Should -Be (Get-Content -LiteralPath $source -Raw -Encoding UTF8)

      $shim = Join-Path -Path $script:syncShimDir -ChildPath "$name.cmd"
      Test-Path -LiteralPath $shim | Should -Be $true
      $shimText = Get-Content -LiteralPath $shim -Raw -Encoding UTF8
      $shimText | Should -Match ([regex]::Escape("-File `"$deployed`""))
      $shimText | Should -Match 'pwsh -NoProfile -ExecutionPolicy Bypass'
      $shimText | Should -Match "`r`n"
    }
  }

  It 'is idempotent — a second enabled run rewrites nothing' {
    $artifacts = @(
      (Join-Path -Path $script:syncBinDir -ChildPath 'harness-notify.ps1')
      (Join-Path -Path $script:syncBinDir -ChildPath 'harness-approval.ps1')
      (Join-Path -Path $script:syncShimDir -ChildPath 'harness-notify.cmd')
      (Join-Path -Path $script:syncShimDir -ChildPath 'harness-approval.cmd')
    )
    $before = $artifacts | ForEach-Object { (Get-Item -LiteralPath $_).LastWriteTimeUtc.Ticks }

    Start-Sleep -Milliseconds 20
    Sync-HarnessBridge -Enabled:$true -RepoRoot $script:syncSandbox.Repo -UserRoot $script:syncUserRoot -UserProfile $script:syncSandbox.Home > $null

    $after = $artifacts | ForEach-Object { (Get-Item -LiteralPath $_).LastWriteTimeUtc.Ticks }
    $after | Should -Be $before
  }

  It 'removes the shims and deployed copies on a disabled run, keeping unmanaged files' {
    $unmanagedShim = Join-Path -Path $script:syncShimDir -ChildPath 'other-tool.cmd'
    $unmanagedBin = Join-Path -Path $script:syncBinDir -ChildPath 'other-tool.ps1'
    $null = Set-Content -Path $unmanagedShim -Value '@echo off' -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
    $null = Set-Content -Path $unmanagedBin -Value '# other' -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup

    Sync-HarnessBridge -Enabled:$false -RepoRoot $script:syncSandbox.Repo -UserRoot $script:syncUserRoot -UserProfile $script:syncSandbox.Home > $null

    foreach ($name in @('harness-approval', 'harness-notify')) {
      Test-Path -LiteralPath (Join-Path -Path $script:syncBinDir -ChildPath "$name.ps1") | Should -Be $false
      Test-Path -LiteralPath (Join-Path -Path $script:syncShimDir -ChildPath "$name.cmd") | Should -Be $false
    }
    Test-Path -LiteralPath $unmanagedShim | Should -Be $true
    Test-Path -LiteralPath $unmanagedBin | Should -Be $true

    # Restore the deployed state for the remaining assertions in this file.
    Sync-HarnessBridge -Enabled:$true -RepoRoot $script:syncSandbox.Repo -UserRoot $script:syncUserRoot -UserProfile $script:syncSandbox.Home > $null
  }
}

Describe 'harness-notify.ps1 Windows twin' {
  BeforeAll {
    $script:notifySandbox = New-HarnessBridgeSandbox
    Write-HermesStub -StubDir $script:notifySandbox.StubDir
    $script:notifyScript = Join-Path -Path $script:NotifyDir -ChildPath 'harness-notify.ps1'
  }

  AfterAll {
    Remove-HarnessBridgeSandbox -Root $script:notifySandbox.Root
  }

  It 'fans one event out to every configured channel with the harness subject' {
    Set-SandboxConfig -Sandbox $script:notifySandbox -Config @{ 'harness-notify' = @{ enable = $true; channels = @('telegram', 'ntfy', 'discord') } }
    $started = Start-TwinProcess -Sandbox $script:notifySandbox -ScriptPath $script:notifyScript -Arguments @('pi', 'done', 'refactor done')
    $result = Wait-TwinProcess -Started $started

    $result.ExitCode | Should -Be 0
    $log = Get-HermesStubLog -Sandbox $script:notifySandbox
    @($log | Where-Object { $_ -like 'ARGV*' }).Count | Should -Be 3
    foreach ($target in @('telegram', 'ntfy', 'discord')) {
      @($log | Where-Object { $_.Contains("--to $target ") }).Count | Should -Be 1
    }
    @($log | Where-Object { $_.Contains('--subject [pi] finished') }).Count | Should -Be 3
    @($log | Where-Object { $_.Contains('BODY refactor done') }).Count | Should -Be 3
  }

  It 'extracts the message from a hook JSON payload when no text is given' {
    Set-SandboxConfig -Sandbox $script:notifySandbox -Config @{ 'harness-notify' = @{ enable = $true; channels = @('telegram') } }
    $started = Start-TwinProcess -Sandbox $script:notifySandbox -ScriptPath $script:notifyScript -Arguments @('opencode', 'done') -Stdin '{"message":"session idle"}'
    $result = Wait-TwinProcess -Started $started

    $result.ExitCode | Should -Be 0
    @((Get-HermesStubLog -Sandbox $script:notifySandbox) | Where-Object { $_.Contains('BODY session idle') }).Count | Should -Be 1
  }

  It 'falls back to the event label when the body is empty' {
    Set-SandboxConfig -Sandbox $script:notifySandbox -Config @{ 'harness-notify' = @{ enable = $true; channels = @('telegram') } }
    $started = Start-TwinProcess -Sandbox $script:notifySandbox -ScriptPath $script:notifyScript -Arguments @('cursor', 'needs-input')
    $result = Wait-TwinProcess -Started $started

    $result.ExitCode | Should -Be 0
    $log = Get-HermesStubLog -Sandbox $script:notifySandbox
    @($log | Where-Object { $_.Contains('--subject [cursor] needs input') }).Count | Should -Be 1
    @($log | Where-Object { $_.Contains('BODY needs input') }).Count | Should -Be 1
  }

  It 'notifies nothing when the bridge is disabled' {
    Set-SandboxConfig -Sandbox $script:notifySandbox -Config @{ 'harness-notify' = @{ enable = $false; channels = @('telegram') } }
    $before = (Get-HermesStubLog -Sandbox $script:notifySandbox).Count
    $started = Start-TwinProcess -Sandbox $script:notifySandbox -ScriptPath $script:notifyScript -Arguments @('pi', 'done', 'ignored')
    $result = Wait-TwinProcess -Started $started

    $result.ExitCode | Should -Be 0
    (Get-HermesStubLog -Sandbox $script:notifySandbox).Count | Should -Be $before
  }

  It 'exits 0 with a warning when arguments are missing' {
    $started = Start-TwinProcess -Sandbox $script:notifySandbox -ScriptPath $script:notifyScript -Arguments @()
    $result = Wait-TwinProcess -Started $started

    $result.ExitCode | Should -Be 0
    $result.Stderr | Should -Match 'harness-notify: warning: usage'
  }
}

Describe 'harness-approval.ps1 Windows twin' {
  BeforeAll {
    $script:approvalSandbox = New-HarnessBridgeSandbox
    Write-HermesStub -StubDir $script:approvalSandbox.StubDir
    $script:approvalScript = Join-Path -Path $script:NotifyDir -ChildPath 'harness-approval.ps1'
  }

  AfterAll {
    Remove-HarnessBridgeSandbox -Root $script:approvalSandbox.Root
  }

  It 'honours a remote allow decision, clears the request, and audits it' {
    Set-SandboxConfig -Sandbox $script:approvalSandbox -Config @{ 'harness-notify' = @{ enable = $true; channels = @('telegram') } }
    $stateDir = Get-BridgeStateDir -Sandbox $script:approvalSandbox
    $started = Start-TwinProcess -Sandbox $script:approvalSandbox -ScriptPath $script:approvalScript -Arguments @('pi', 'bash', 'git push --force', '30')

    $requestPath = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while ($null -eq $requestPath -and [DateTime]::UtcNow -lt $deadline) {
      $candidate = Get-ChildItem -LiteralPath (Join-Path -Path $stateDir -ChildPath 'requests') -Filter '*.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1  # check-suppress:suppression_doc: absence means the request is not written yet; polling continues
      if ($null -ne $candidate) { $requestPath = $candidate.FullName }
      elseif (-not $started.Process.HasExited) { Start-Sleep -Milliseconds 200 }
      else { break }
    }

    if ($null -eq $requestPath) {
      $started.Process.Kill()
      throw 'no approval request file appeared'
    }

    $request = Get-Content -LiteralPath $requestPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    $request['harness'] | Should -Be 'pi'
    $request['tool'] | Should -Be 'bash'
    $request['summary'] | Should -Be 'git push --force'

    $responsePath = Join-Path -Path (Join-Path -Path $stateDir -ChildPath 'responses') -ChildPath (Split-Path -Path $requestPath -Leaf)
    [System.IO.File]::WriteAllText($responsePath, '{"decision":"allow","decided_by":"test"}', [System.Text.UTF8Encoding]::new($false))

    $result = Wait-TwinProcess -Started $started
    $result.ExitCode | Should -Be 0
    $result.Stdout | Should -Be 'allow'

    @(Get-ChildItem -LiteralPath $stateDir -Recurse -Filter '*.json' -File).Count | Should -Be 0

    $auditLog = Join-Path -Path (Join-Path -Path $script:approvalSandbox.LocalApp -ChildPath 'nucleus\log') -ChildPath 'harness-bridge.log'
    Test-Path -LiteralPath $auditLog | Should -Be $true
    (Get-Content -LiteralPath $auditLog -Raw -Encoding UTF8) | Should -Match "pi`tbash`tallow"
  }

  It 'answers Cursor hook mode with a Cursor permission document when nobody answers' {
    Set-SandboxConfig -Sandbox $script:approvalSandbox -Config @{ 'harness-notify' = @{ enable = $true; channels = @('telegram') }; 'harness-approval' = @{ 'timeout-seconds' = 2 } }
    $started = Start-TwinProcess -Sandbox $script:approvalSandbox -ScriptPath $script:approvalScript -Arguments @('hook', 'cursor') -Stdin '{"command":"rm -rf build"}'
    $result = Wait-TwinProcess -Started $started

    $result.ExitCode | Should -Be 0
    $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
    $document['permission'] | Should -Be 'ask'

    $log = Get-HermesStubLog -Sandbox $script:approvalSandbox
    @($log | Where-Object { $_.Contains('--subject [cursor] approval needed') }).Count | Should -BeGreaterThan 0
    @($log | Where-Object { $_.Contains('hook: rm -rf build') }).Count | Should -BeGreaterThan 0
  }

  It 'answers Copilot hook mode with a PreToolUse decision document' {
    Set-SandboxConfig -Sandbox $script:approvalSandbox -Config @{ 'harness-notify' = @{ enable = $true; channels = @('telegram') }; 'harness-approval' = @{ 'timeout-seconds' = 2 } }
    $started = Start-TwinProcess -Sandbox $script:approvalSandbox -ScriptPath $script:approvalScript -Arguments @('hook', 'copilot') -Stdin '{"tool_name":"runInTerminal","tool_input":{"command":"rm -rf /"}}'
    $result = Wait-TwinProcess -Started $started

    $result.ExitCode | Should -Be 0
    $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
    $document['hookSpecificOutput']['hookEventName'] | Should -Be 'PreToolUse'
    $document['hookSpecificOutput']['permissionDecision'] | Should -Be 'ask'
    $document['hookSpecificOutput']['permissionDecisionReason'] | Should -Be 'nucleus harness-approval'
  }

  It 'renders the plain decision for harnesses without a document shape' {
    Set-SandboxConfig -Sandbox $script:approvalSandbox -Config @{ 'harness-notify' = @{ enable = $true; channels = @('telegram') }; 'harness-approval' = @{ 'timeout-seconds' = 2 } }
    $started = Start-TwinProcess -Sandbox $script:approvalSandbox -ScriptPath $script:approvalScript -Arguments @('hook', 'opencode') -Stdin '{"title":"run bash"}'
    $result = Wait-TwinProcess -Started $started

    $result.ExitCode | Should -Be 0
    $result.Stdout | Should -Be 'ask'
  }

  It 'still exits 0 with a decision when the payload is malformed' {
    Set-SandboxConfig -Sandbox $script:approvalSandbox -Config @{ 'harness-notify' = @{ enable = $true; channels = @('telegram') }; 'harness-approval' = @{ 'timeout-seconds' = 2 } }
    $started = Start-TwinProcess -Sandbox $script:approvalSandbox -ScriptPath $script:approvalScript -Arguments @('hook', 'cursor') -Stdin 'not json at all'
    $result = Wait-TwinProcess -Started $started

    $result.ExitCode | Should -Be 0
    $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
    $document['permission'] | Should -Be 'ask'
  }
}
