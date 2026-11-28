<#
.SYNOPSIS
  Pester coverage for the Windows approval resolver's typed decision contract.

.DESCRIPTION
  The resolver prints one JSON decision document for every caller. These cases
  run the shipped script as a child process with a private HOME and LOCALAPPDATA,
  so the config and the Hermes state tree belong to the fixture rather than to
  the machine running the suite. Prompt cases need a real console and live in
  the POSIX pty suite; the Hermes cases here need only a response file.

.NOTES
  Run with: pwsh -File tests/platforms/Windows/modules/harness/HarnessApproval.Tests.ps1
  Exit codes: 0 when every case passes, otherwise the number of failed cases.
#>

# Invoke-Pester dot-sources this file, so the marker keeps a direct run from
# starting a second nested invocation of the same tests.
if ($env:NUCLEUS_HARNESS_APPROVAL_PESTER -ne '1') {
  $env:NUCLEUS_HARNESS_APPROVAL_PESTER = '1'
  Import-Module Pester -MinimumVersion 5.0
  $result = Invoke-Pester -Path $PSCommandPath -Output Detailed -PassThru
  exit $result.FailedCount
}

BeforeAll {
  $script:RepoRootPath = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..')).Path
  $script:ResolverPath = Join-Path -Path $script:RepoRootPath -ChildPath 'src\scripts\notify\harness\request-approval.ps1'
  $script:WrapperPath = Join-Path -Path $script:RepoRootPath -ChildPath 'scripts\utils.ps1'
  $script:ConfigPath = Join-Path -Path $script:RepoRootPath -ChildPath 'scripts\config.ps1'
  $script:PwshPath = [Environment]::ProcessPath

  function Initialize-ApprovalFixture {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nucleus-happroval-" + [guid]::NewGuid().ToString('N'))
    $homePath = Join-Path -Path $root -ChildPath 'home'
    $localAppData = Join-Path -Path $root -ChildPath 'appdata'
    $directories = @(
      $homePath,
      $localAppData,
      (Join-Path -Path $homePath -ChildPath '.local/state/nucleus'),
      (Join-Path -Path $root -ChildPath 'logs')
    )
    foreach ($directory in $directories) {
      $null = New-Item -ItemType Directory -Path $directory -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in fixture setup
    }
    return @{
      Root         = $root
      Home         = $homePath
      LocalAppData = $localAppData
      Config       = Join-Path -Path $homePath -ChildPath '.local/state/nucleus/config.json'
      Logs         = Join-Path -Path $root -ChildPath 'logs'
    }
  }

  function New-ApprovalProcess {
    # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- test helper spawns a child under the suite's temp fixture; -WhatIf would break every case that needs a live process
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([System.Diagnostics.Process])]
    param(
      [Parameter(Mandatory)]
      [string]$FilePath,

      [Parameter(Mandatory)]
      [string[]]$Arguments,

      [Parameter(Mandatory)]
      [hashtable]$Fixture
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['HOME'] = $Fixture.Home
    $startInfo.EnvironmentVariables['LOCALAPPDATA'] = $Fixture.LocalAppData
    $startInfo.EnvironmentVariables['NUCLEUS_LOG_DIR'] = $Fixture.Logs
    $startInfo.EnvironmentVariables['NUCLEUS_REPO_ROOT'] = $Fixture.Root
    return [System.Diagnostics.Process]::Start($startInfo)
  }

  function Read-ApprovalProcess {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
      [Parameter(Mandatory)]
      [System.Diagnostics.Process]$Process
    )

    $stdout = $Process.StandardOutput.ReadToEnd()
    $stderr = $Process.StandardError.ReadToEnd()
    $Process.WaitForExit()
    return @{ ExitCode = $Process.ExitCode; Document = $stdout.Trim(); Stderr = $stderr }
  }

  function Write-ApprovalConfig {
    [CmdletBinding()]
    param(
      [Parameter(Mandatory)]
      [hashtable]$Fixture,

      [Parameter(Mandatory)]
      [string]$Document
    )

    [System.IO.File]::WriteAllText($Fixture.Config, $Document, [System.Text.UTF8Encoding]::new($false))
  }

  function Wait-ApprovalRequest {
    [CmdletBinding()]
    [OutputType([string])]
    param(
      [Parameter(Mandatory)]
      [hashtable]$Fixture
    )

    $requests = Join-Path -Path $Fixture.LocalAppData -ChildPath 'nucleus/state/harness-bridge/requests'
    for ($index = 0; $index -lt 60; $index++) {
      $files = @(Get-ChildItem -LiteralPath $requests -Filter '*.json' -File -ErrorAction SilentlyContinue)
      if ($files.Count -gt 0) { return $files[0].FullName }
      Start-Sleep -Milliseconds 200
    }
    return ''
  }

  function Write-ApprovalResponse {
    [CmdletBinding()]
    param(
      [Parameter(Mandatory)]
      [string]$RequestFile,

      [Parameter(Mandatory)]
      [string]$Document
    )

    $state = Split-Path -Path (Split-Path -Path $RequestFile -Parent) -Parent
    $responses = Join-Path -Path $state -ChildPath 'responses'
    $null = New-Item -ItemType Directory -Path $responses -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in fixture setup
    $path = Join-Path -Path $responses -ChildPath (Split-Path -Path $RequestFile -Leaf)
    [System.IO.File]::WriteAllText($path, $Document, [System.Text.UTF8Encoding]::new($false))
  }
}

AfterAll {
  if ($script:ApprovalFixture -and (Test-Path -LiteralPath $script:ApprovalFixture.Root)) {
    Remove-Item -LiteralPath $script:ApprovalFixture.Root -Recurse -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: cleanup in test teardown, a failure is acceptable
  }
}

Describe 'Windows approval resolver contract' {
  It 'ships both sources and 300/600 timeouts in nucleus-config' {
    $fixture = Initialize-ApprovalFixture
    $process = New-ApprovalProcess -FilePath $script:PwshPath -Arguments @('-NoProfile', '-File', $script:ConfigPath, 'get', 'harness-approval') -Fixture $fixture
    $result = Read-ApprovalProcess -Process $process
    $result.ExitCode | Should -Be 0
    # WHY parse rather than compare text: PowerShell serializes a hashtable in
    # insertion order, so the timeout keys can change places without changing
    # the defaults the operator reads.
    $defaults = $result.Document | ConvertFrom-Json -AsHashtable
    (@($defaults['sources']) -join ',') | Should -Be 'prompt,hermes'
    $defaults['timeout-seconds']['hermes'] | Should -Be 300
    $defaults['timeout-seconds']['prompt'] | Should -Be 600
  }

  It 'emits a typed ask with the none source when no sources are enabled' {
    $script:ApprovalFixture = Initialize-ApprovalFixture
    Write-ApprovalConfig -Fixture $script:ApprovalFixture -Document '{"harness-approval":{"sources":[],"timeout-seconds":{"hermes":1,"prompt":1}}}'
    $process = New-ApprovalProcess -FilePath $script:PwshPath -Arguments @('-NoProfile', '-File', $script:ResolverPath, 'pi', 'bash', 'rm x', '1') -Fixture $script:ApprovalFixture
    $result = Read-ApprovalProcess -Process $process
    $result.ExitCode | Should -Be 0
    $result.Document | Should -Be '{"version":1,"decision":"ask","reason":"no approval sources enabled","source":"none","timeouts":{"hermes":300,"prompt":600},"timedOutSources":[]}'
  }

  It 'emits a typed resolver-error deny for an unparsable config' {
    $script:ApprovalFixture = Initialize-ApprovalFixture
    Write-ApprovalConfig -Fixture $script:ApprovalFixture -Document '{'
    $process = New-ApprovalProcess -FilePath $script:PwshPath -Arguments @('-NoProfile', '-File', $script:ResolverPath, 'pi', 'bash', 'rm x', '1') -Fixture $script:ApprovalFixture
    $result = Read-ApprovalProcess -Process $process
    $result.ExitCode | Should -Be 0
    $result.Document | Should -Be '{"version":1,"decision":"deny","reason":"could not parse nucleus config","source":"resolver-error","timeouts":{"hermes":300,"prompt":600},"timedOutSources":[]}'
  }

  It 'carries the response reason into a Hermes deny document' {
    $script:ApprovalFixture = Initialize-ApprovalFixture
    Write-ApprovalConfig -Fixture $script:ApprovalFixture -Document '{"harness-approval":{"sources":["hermes"],"timeout-seconds":{"hermes":30,"prompt":1}}}'
    $process = New-ApprovalProcess -FilePath $script:PwshPath -Arguments @('-NoProfile', '-File', $script:ResolverPath, 'pi', 'bash', 'rm x', '30') -Fixture $script:ApprovalFixture
    $request = Wait-ApprovalRequest -Fixture $script:ApprovalFixture
    $request | Should -Not -BeNullOrEmpty
    Write-ApprovalResponse -RequestFile $request -Document '{"decision":"deny","decided_by":"chat","reason":"denied by chat"}'
    $result = Read-ApprovalProcess -Process $process
    $result.ExitCode | Should -Be 0
    $document = $result.Document | ConvertFrom-Json -AsHashtable
    $document['version'] | Should -Be 1
    $document['decision'] | Should -Be 'deny'
    $document['reason'] | Should -Be 'denied by chat'
    $document['source'] | Should -Be 'hermes'
    $document['timeouts']['hermes'] | Should -Be 300
    $document['timeouts']['prompt'] | Should -Be 600
    @($document['timedOutSources']).Count | Should -Be 0
  }

  It 'emits a typed resolver-error deny for a malformed Hermes response' {
    $script:ApprovalFixture = Initialize-ApprovalFixture
    Write-ApprovalConfig -Fixture $script:ApprovalFixture -Document '{"harness-approval":{"sources":["hermes"],"timeout-seconds":{"hermes":30,"prompt":1}}}'
    $process = New-ApprovalProcess -FilePath $script:PwshPath -Arguments @('-NoProfile', '-File', $script:ResolverPath, 'pi', 'bash', 'rm x', '30') -Fixture $script:ApprovalFixture
    $request = Wait-ApprovalRequest -Fixture $script:ApprovalFixture
    $request | Should -Not -BeNullOrEmpty
    Write-ApprovalResponse -RequestFile $request -Document '{"decision":"maybe","decided_by":"chat","reason":"odd"}'
    $result = Read-ApprovalProcess -Process $process
    $result.ExitCode | Should -Be 0
    $result.Document | Should -Be '{"version":1,"decision":"deny","reason":"malformed hermes approval response","source":"resolver-error","timeouts":{"hermes":300,"prompt":600},"timedOutSources":[]}'
  }

  It 'renders an exact all-timeout document with the sources in contract order' {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ResolverPath, [ref]$tokens, [ref]$parseErrors)
    $parseErrors | Should -BeNullOrEmpty
    $converter = $ast.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'ConvertTo-HarnessApprovalDocument'
    }, $true) | Select-Object -First 1
    $converter | Should -Not -BeNullOrEmpty
    . ([scriptblock]::Create($converter.Extent.Text))
    $document = ConvertTo-HarnessApprovalDocument -Decision 'deny' -Reason 'all approval sources timed out (hermes 300s, prompt 600s)' -Source 'all-timeouts' -TimedOutSources @('prompt', 'hermes')
    $document | Should -Be '{"version":1,"decision":"deny","reason":"all approval sources timed out (hermes 300s, prompt 600s)","source":"all-timeouts","timeouts":{"hermes":300,"prompt":600},"timedOutSources":["hermes","prompt"]}'
  }

  It 'turns an invalid wrapper timeout into a typed resolver-error document' {
    $script:ApprovalFixture = Initialize-ApprovalFixture
    Write-ApprovalConfig -Fixture $script:ApprovalFixture -Document '{"harness-approval":{"sources":[],"timeout-seconds":{"hermes":30,"prompt":1}}}'
    $arguments = @('-NoProfile', '-File', $script:WrapperPath, 'harness', 'request-approval', 'pi', 'bash', 'rm x', 'later')
    $process = New-ApprovalProcess -FilePath $script:PwshPath -Arguments $arguments -Fixture $script:ApprovalFixture
    $result = Read-ApprovalProcess -Process $process
    $result.ExitCode | Should -Be 0
    $result.Document | Should -Be '{"version":1,"decision":"deny","reason":"the timeout argument must be a whole number of seconds","source":"resolver-error","timeouts":{"hermes":300,"prompt":600},"timedOutSources":[]}'
  }
}
