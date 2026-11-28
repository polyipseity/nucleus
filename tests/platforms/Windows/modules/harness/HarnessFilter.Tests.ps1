<#
.SYNOPSIS
  Pester coverage for the Windows harness decision runner and its filter.

.DESCRIPTION
  Covers the twin of decide-call.sh: the render table (Cursor and Copilot
  documents, typed decision document for the rest), the safe-delete filter's rule families and
  its settings.unproven question, and the aggregation and failure rules.

  Every case runs the real deployed bytes from a fixture repository tree, so the
  runner resolves the real filters beside itself and the registry through
  NUCLEUS_REPO_ROOT, and no case can touch the developer's registry.

.NOTES
  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/harness/HarnessFilter.Tests.ps1 -Output Detailed"

  Environment: NUCLEUS_REPO_ROOT is set for the child processes only.

  Exit codes: 0 on success; 1 on failure.
#>

BeforeAll {
  $script:RepoRootPath = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..')).Path
  $script:NotifyDir = Join-Path -Path $script:RepoRootPath -ChildPath 'src\scripts\notify'
  $script:FiltersDir = Join-Path -Path $script:NotifyDir -ChildPath 'filters'
  $script:RegistryPath = Join-Path -Path (Join-Path -Path $script:RepoRootPath -ChildPath 'src\modules\configs') -ChildPath 'harness-filters.json'
  $script:SchemaPath = Join-Path -Path (Join-Path -Path $script:RepoRootPath -ChildPath 'src\modules\configs') -ChildPath 'harness-filters.schema.json'
  $script:PwshPath = [Environment]::ProcessPath
  $script:ResolverPath = Join-Path -Path $script:NotifyDir -ChildPath 'harness\request-approval.ps1'
  $script:TypedReason = 'all approval sources timed out (hermes 300s, prompt 600s)'
  $script:TypedDeny = '{"version":1,"decision":"deny","reason":"all approval sources timed out (hermes 300s, prompt 600s)","source":"all-timeouts","timeouts":{"hermes":300,"prompt":600},"timedOutSources":["hermes","prompt"]}'

  function New-FilterSandbox {
    <#
    .SYNOPSIS
      Copies the runner, its filters, and the registry into a fixture tree.
    .DESCRIPTION
      The runner resolves filters beside itself and the registry through
      NUCLEUS_REPO_ROOT, so a fixture tree is what makes a synthetic filter or a
      replaced registry reachable without touching the checkout.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param()

    $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) ("nucleus-hfilter-" + [guid]::NewGuid().ToString('N'))
    # WHY ShouldProcess: New- is a should-process verb, so the analyzer requires the
    # gate; the body only ever writes inside the temp path it just computed.
    if (-not $PSCmdlet.ShouldProcess($root, 'create the filter fixture tree')) {
      return $root
    }
    $notifyCopy = Join-Path -Path $root 'src\scripts\notify'
    $configCopy = Join-Path -Path $root 'src\modules\configs'
    foreach ($dir in @($notifyCopy, (Join-Path -Path $notifyCopy 'filters'), $configCopy)) {
      $null = New-Item -ItemType Directory -Path $dir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
    }

    Copy-Item -LiteralPath (Join-Path -Path $script:NotifyDir -ChildPath 'harness-bridge-common.ps1') -Destination (Join-Path -Path $notifyCopy -ChildPath 'harness-bridge-common.ps1')
    $harnessCopy = Join-Path -Path $notifyCopy -ChildPath 'harness'
    $null = New-Item -ItemType Directory -Path $harnessCopy -Force # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
    foreach ($name in @('decide-call.ps1', 'request-approval.ps1', 'send-notification.ps1')) {
      Copy-Item -LiteralPath (Join-Path -Path $script:NotifyDir -ChildPath "harness\$name") -Destination (Join-Path -Path $harnessCopy -ChildPath $name)
    }
    foreach ($filter in @(Get-ChildItem -LiteralPath $script:FiltersDir -File -Filter '*.ts')) {
      Copy-Item -LiteralPath $filter.FullName -Destination (Join-Path -Path (Join-Path -Path $notifyCopy 'filters') -ChildPath $filter.Name)
    }
    Copy-Item -LiteralPath $script:RegistryPath -Destination (Join-Path -Path $configCopy -ChildPath 'harness-filters.json')

    # The runner audits through the nucleus-logs entry script, which imports the
    # output and log-management modules from the repository it lives in, so the
    # fixture carries all three beside a sandbox log root.
    $scriptsCopy = Join-Path -Path $root 'scripts'
    $modulesCopy = Join-Path -Path (Join-Path -Path $root 'src\platforms\Windows') -ChildPath 'modules'
    foreach ($dir in @($scriptsCopy, $modulesCopy)) {
      $null = New-Item -ItemType Directory -Path $dir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
    }
    Copy-Item -LiteralPath (Join-Path -Path $script:RepoRootPath -ChildPath 'scripts\logs.ps1') -Destination (Join-Path -Path $scriptsCopy -ChildPath 'logs.ps1')
    foreach ($name in @('Format-NucleusOutput.psm1', 'Get-NucleusHostPlatform.ps1', 'Invoke-LogManagement.ps1')) {
      Copy-Item -LiteralPath (Join-Path -Path $script:RepoRootPath -ChildPath "src\platforms\Windows\modules\$name") -Destination (Join-Path -Path $modulesCopy -ChildPath $name)
    }
    # logs.ps1 dot-sources these relative to its own location; without them the
    # audit append fails in the fixture and the shared audit log is never written.
    $scriptLibCopy = Join-Path -Path (Join-Path -Path $root 'src\scripts') -ChildPath 'lib'
    $null = New-Item -ItemType Directory -Path $scriptLibCopy -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
    foreach ($name in @('pwsh-guard.ps1', 'nucleus-cli-flags.ps1')) {
      Copy-Item -LiteralPath (Join-Path -Path $script:RepoRootPath -ChildPath "src\scripts\lib\$name") -Destination (Join-Path -Path $scriptLibCopy -ChildPath $name)
    }
    return $root
  }

  function New-FilterHome {
    <#
    .SYNOPSIS
      Builds the HOME the runner sees, with a known redirect state.
    .DESCRIPTION
      The real user's wrappers and approval config must not decide these cases.
      The wrapper home additionally carries two managed wrappers so the profile
      cases have the same answer on POSIX hosts; the default home has none, so
      a bare delete stays unproven and the resolver answers ask at once.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param(
      [Parameter(Mandatory)]
      [string]$Root,

      [string]$Name = 'home',

      [switch]$WithPOSIXWrappers,

      [string[]]$WrapperWords = @('DEL', 'Remove-Item')
    )

    $filterHomePath = Join-Path -Path $Root -ChildPath $Name
    $wrapperDir = Join-Path -Path $filterHomePath -ChildPath '.local/bin'
    $targetDir = Join-Path -Path $Root -ChildPath 'store/home-manager-files/.local/bin'
    $configDir = Join-Path -Path $filterHomePath -ChildPath '.local/state/nucleus'
    foreach ($dir in @($wrapperDir, $targetDir, $configDir)) {
      if (-not $PSCmdlet.ShouldProcess($dir, 'create the filter home directory')) { continue }
      $null = New-Item -ItemType Directory -Path $dir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
    }
    [System.IO.File]::WriteAllText(
      (Join-Path -Path $configDir -ChildPath 'config.json'),
      '{"harness-approval":{"sources":[]}}',
      [System.Text.UTF8Encoding]::new($false)
    )
    if ($WithPOSIXWrappers -and -not $IsWindows) {
      foreach ($word in $WrapperWords) {
        $target = Join-Path -Path $targetDir -ChildPath $word
        [System.IO.File]::WriteAllText($target, "#!/bin/sh`nexit 0`n", [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::SetUnixFileMode($target, [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite -bor [System.IO.UnixFileMode]::UserExecute)
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path -Path $wrapperDir -ChildPath $word) -Target $target  # check-suppress:suppression_doc: New-Item returns FileInfo, discarded in test setup
      }
    }
    return $filterHomePath
  }

  function Remove-FilterSandbox {
    <#
    .SYNOPSIS
      Deletes a fixture tree.
    .PARAMETER Root
      Fixture root directory.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
      [Parameter(Mandatory)]
      [string]$Root
    )

    if (Test-Path -LiteralPath $Root) {
      # WHY ShouldProcess: Remove- is a should-process verb, so the analyzer requires
      # the gate; a test helper must still call it rather than only declare it.
      if (-not $PSCmdlet.ShouldProcess($Root, 'remove the filter fixture tree')) { return }
      Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: cleanup in test teardown, a failure is acceptable
    }
  }

  function Set-FilterRegistry {
    <#
    .SYNOPSIS
      Replaces the fixture registry.
    .PARAMETER Root
      Fixture root directory.
    .PARAMETER Document
      Registry document as JSON.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
      [Parameter(Mandatory)]
      [string]$Root,

      [Parameter(Mandatory)]
      [string]$Document
    )

    $path = Join-Path -Path (Join-Path -Path $Root 'src\modules\configs') -ChildPath 'harness-filters.json'
    # WHY ShouldProcess: Set- is a should-process verb, so the analyzer requires the
    # gate; a test helper must still call it rather than only declare it.
    if (-not $PSCmdlet.ShouldProcess($path, 'replace the fixture filter registry')) { return }
    [System.IO.File]::WriteAllText($path, $Document, [System.Text.UTF8Encoding]::new($false))
  }

  function Set-ApprovalResolverDocument {
    <#
    .SYNOPSIS
      Replaces the fixture resolver with a one-document stand-in.
    .PARAMETER Root
      Fixture root directory.
    .PARAMETER Document
      Typed decision document the stand-in prints.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
      [Parameter(Mandatory)]
      [string]$Root,

      [Parameter(Mandatory)]
      [string]$Document
    )

    $path = Join-Path -Path (Join-Path -Path $Root 'src\scripts\notify') -ChildPath 'harness\request-approval.ps1'
    # WHY ShouldProcess: Set- is a should-process verb, so the analyzer requires the
    # gate; the body only writes inside the fixture tree.
    if (-not $PSCmdlet.ShouldProcess($path, 'replace the fixture approval resolver')) { return }
    $body = "[Console]::Error.WriteLine('decoy ask')`n[Console]::Out.WriteLine('$Document')`nexit 0`n"
    [System.IO.File]::WriteAllText($path, $body, [System.Text.UTF8Encoding]::new($false))
  }

  function Add-FilterScript {
    <#
    .SYNOPSIS
      Adds a synthetic filter beside the real ones.
    .PARAMETER Root
      Fixture root directory.
    .PARAMETER Id
      Filter id the registry names.
    .PARAMETER Body
      JavaScript body, which prints the protocol line.
    #>
    [CmdletBinding()]
    param(
      [Parameter(Mandatory)]
      [string]$Root,

      [Parameter(Mandatory)]
      [string]$Id,

      [Parameter(Mandatory)]
      [string]$Body
    )

    $path = Join-Path -Path (Join-Path -Path $Root 'src\scripts\notify\filters') -ChildPath "$Id.ts"
    [System.IO.File]::WriteAllText($path, $Body, [System.Text.UTF8Encoding]::new($false))
  }

  function Invoke-FilterTwin {
    <#
    .SYNOPSIS
      Runs the deployed runner as a child process.
    .PARAMETER Root
      Fixture root directory, exported as NUCLEUS_REPO_ROOT.
    .PARAMETER Harness
      Harness name.
    .PARAMETER Payload
      Hook payload written to the child's stdin.
    .PARAMETER HomePath
      Fixture home, which controls the redirect proof.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
      [Parameter(Mandatory)]
      [string]$Root,

      [Parameter(Mandatory)]
      [string]$Harness,

      [Parameter(Mandatory)]
      [string]$Payload,

      [string]$HomePath = $script:FilterHome
    )

    $previous = $env:NUCLEUS_REPO_ROOT
    $previousLogDir = $env:NUCLEUS_LOG_DIR
    $previousHome = [Environment]::GetEnvironmentVariable('HOME', 'Process')
    $previousLocalAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA', 'Process')
    $previousPath = [Environment]::GetEnvironmentVariable('PATH', 'Process')
    $env:NUCLEUS_REPO_ROOT = $Root
    $env:NUCLEUS_LOG_DIR = Join-Path -Path $Root 'logs'
    $fixtureBin = Join-Path -Path $HomePath -ChildPath '.local/bin'
    [Environment]::SetEnvironmentVariable('HOME', $HomePath, 'Process')
    if ($IsWindows) {
      [Environment]::SetEnvironmentVariable('LOCALAPPDATA', (Join-Path -Path $HomePath -ChildPath 'AppData/Local'), 'Process')
      [Environment]::SetEnvironmentVariable('PATH', "$fixtureBin;$previousPath", 'Process')
    }
    else {
      [Environment]::SetEnvironmentVariable('PATH', "$fixtureBin`:$previousPath", 'Process')
    }
    try {
      $runner = Join-Path -Path (Join-Path -Path $Root 'src\scripts\notify') -ChildPath 'harness\decide-call.ps1'
      $stdout = @($Payload | & $script:PwshPath -NoProfile -File $runner $Harness 2>$null) -join "`n"
      return @{ ExitCode = $LASTEXITCODE; Stdout = $stdout }
    }
    finally {
      $env:NUCLEUS_REPO_ROOT = $previous
      $env:NUCLEUS_LOG_DIR = $previousLogDir
      [Environment]::SetEnvironmentVariable('HOME', $previousHome, 'Process')
      [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $previousLocalAppData, 'Process')
      [Environment]::SetEnvironmentVariable('PATH', $previousPath, 'Process')
    }
  }

  $script:Sandbox = New-FilterSandbox
  $script:FilterHome = New-FilterHome -Root $script:Sandbox
  $script:FilterProfileHome = New-FilterHome -Root $script:Sandbox -Name 'profile-home' -WithPOSIXWrappers
  # A lowercase wrapper needs a lowercase link target, so the case cannot share
  # the uppercase home on a case-insensitive filesystem.
  $script:FilterLowerProfileHome = New-FilterHome -Root $script:Sandbox -Name 'lower-profile-home' -WithPOSIXWrappers -WrapperWords @('DEL', 'remove-item')
}

AfterAll {
  Remove-FilterSandbox -Root $script:Sandbox
}

Describe 'harness-filter render table' {
  It 'records its verdict as one filter event in the shared audit log' {
    $auditLog = Join-Path -Path (Join-Path -Path $script:Sandbox -ChildPath 'logs') -ChildPath 'harness.log'
    if (Test-Path -LiteralPath $auditLog) { Remove-Item -LiteralPath $auditLog -Force }

    $null = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"tool_name":"runInTerminal","tool_input":{"command":"/bin/rm -rf x"}}'

    $events = @(Get-Content -LiteralPath $auditLog -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
    $filters = @($events | Where-Object { $_.kind -eq 'filter' })
    $filters.Count | Should -Be 1
    $filters[0].decision | Should -Be 'deny'
    $filters[0].source | Should -Be 'filter'
    $filters[0].filter | Should -Be 'safe-delete'
    $filters[0].rule | Should -Be 'native-path'
    $filters[0].latency_ms | Should -BeGreaterOrEqual 0
    $filters[0].digest | Should -Not -BeNullOrEmpty
    $filters[0].ts | Should -Not -BeNullOrEmpty
    $filters[0].id | Should -Match '^[0-9a-f]{8}$'
  }

  It 'denies a native rm path with a Copilot PreToolUse document' {
    $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"tool_name":"runInTerminal","tool_input":{"command":"/bin/rm -rf x"}}'

    $result.ExitCode | Should -Be 0
    $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
    $document['hookSpecificOutput']['hookEventName'] | Should -Be 'PreToolUse'
    $document['hookSpecificOutput']['permissionDecision'] | Should -Be 'deny'
    $document['hookSpecificOutput']['permissionDecisionReason'] | Should -Match 'safe-delete \(native-path\)'
  }

  It 'renders the Cursor permission document byte-identically' {
    $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'cursor' -Payload '{"command":"/bin/rm -rf x"}'

    $result.ExitCode | Should -Be 0
    $result.Stdout | Should -Be '{"permission":"deny"}'
  }

  It 'asks for a plain delete whose redirect is unproven' {
    $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"command":"rm x"}'

    $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
    $document['hookSpecificOutput']['permissionDecision'] | Should -Be 'ask'
    $document['hookSpecificOutput']['permissionDecisionReason'] | Should -Match 'unproven-redirect'
  }

  It 'prints the typed deny document for pi, codex, and an unknown harness' {
    foreach ($harness in @('pi', 'codex', 'unknown-harness')) {
      $result = Invoke-FilterTwin -Root $script:Sandbox -Harness $harness -Payload '{"command":"/bin/rm x"}'
      $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
      $document['version'] | Should -Be 1
      $document['decision'] | Should -Be 'deny'
      $document['source'] | Should -Be 'none'
      $document['timeouts']['hermes'] | Should -Be 300
      $document['timeouts']['prompt'] | Should -Be 600
      $document['reason'] | Should -Match 'safe-delete \(native-path\)'
    }
  }

  It 'allows a command no filter matches with a typed document' {
    $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'opencode' -Payload '{"command":"ls -la"}'

    $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
    $document['version'] | Should -Be 1
    $document['decision'] | Should -Be 'allow'
    @($document['timedOutSources']).Count | Should -Be 0
  }

  It 'asks for a payload that carries no shell command' {
    $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"tool_name":"readFile","tool_input":{"path":"x"}}'

    $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
    $document['hookSpecificOutput']['permissionDecision'] | Should -Be 'ask'
    $document['hookSpecificOutput']['permissionDecisionReason'] | Should -Match 'not-a-command'
  }
}

Describe 'typed resolver rendering' {
  It 'renders the typed deny in each harness vocabulary' {
    Set-FilterRegistry -Root $script:Sandbox -Document '{"filters":[{"enabled":false,"id":"safe-delete","settings":{}}]}'
    Set-ApprovalResolverDocument -Root $script:Sandbox -Document $script:TypedDeny
    try {
      $copilot = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"command":"anything"}'
      $copilot.ExitCode | Should -Be 0
      $copilotDocument = ConvertFrom-Json -InputObject $copilot.Stdout -AsHashtable
      $copilotDocument['hookSpecificOutput']['permissionDecision'] | Should -Be 'deny'
      $copilotDocument['hookSpecificOutput']['permissionDecisionReason'] | Should -Be $script:TypedReason

      $claude = Invoke-FilterTwin -Root $script:Sandbox -Harness 'claude' -Payload '{"command":"anything"}'
      $claudeDocument = ConvertFrom-Json -InputObject $claude.Stdout -AsHashtable
      $claudeDocument['hookSpecificOutput']['permissionDecisionReason'] | Should -Be $script:TypedReason

      $cursor = Invoke-FilterTwin -Root $script:Sandbox -Harness 'cursor' -Payload '{"command":"anything"}'
      $cursor.Stdout | Should -Be '{"permission":"deny"}'

      foreach ($harness in @('pi', 'opencode', 'codex', 'unknown-harness')) {
        $result = Invoke-FilterTwin -Root $script:Sandbox -Harness $harness -Payload '{"command":"anything"}'
        $result.Stdout | Should -Be $script:TypedDeny
      }
    }
    finally {
      Copy-Item -LiteralPath $script:RegistryPath -Destination (Join-Path -Path (Join-Path -Path $script:Sandbox 'src\modules\configs') -ChildPath 'harness-filters.json') -Force
      Copy-Item -LiteralPath $script:ResolverPath -Destination (Join-Path -Path (Join-Path -Path $script:Sandbox 'src\scripts\notify\harness') -ChildPath 'request-approval.ps1') -Force
    }
  }

  It 'does not act on a typed resolver document with an extra top-level key' {
    Set-FilterRegistry -Root $script:Sandbox -Document '{"filters":[{"enabled":false,"id":"safe-delete","settings":{}}]}'
    $extraDocument = ($script:TypedDeny | ConvertFrom-Json -AsHashtable)
    $extraDocument['extra'] = 'unexpected'
    Set-ApprovalResolverDocument -Root $script:Sandbox -Document ($extraDocument | ConvertTo-Json -Compress -Depth 5)
    try {
      $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'pi' -Payload '{"command":"anything"}'
      $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
      $document['decision'] | Should -Be 'ask'
      $document['reason'] | Should -Match 'no-filter'
      $document['reason'] | Should -Not -Match 'all approval sources timed out'
    }
    finally {
      Copy-Item -LiteralPath $script:RegistryPath -Destination (Join-Path -Path (Join-Path -Path $script:Sandbox 'src\modules\configs') -ChildPath 'harness-filters.json') -Force
      Copy-Item -LiteralPath $script:ResolverPath -Destination (Join-Path -Path (Join-Path -Path $script:Sandbox 'src\scripts\notify\harness') -ChildPath 'request-approval.ps1') -Force
    }
  }
}

Describe 'safe-delete filter settings' {
  It 'allows a plain delete when settings.unproven is allow' {
    Set-FilterRegistry -Root $script:Sandbox -Document '{"filters":[{"enabled":true,"id":"safe-delete","settings":{"unproven":"allow"}}]}'
    try {
      $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"command":"rm x"}'
      $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
      $document['hookSpecificOutput']['permissionDecision'] | Should -Be 'allow'
      $document['hookSpecificOutput']['permissionDecisionReason'] | Should -Match 'unproven-redirect'
    }
    finally { Copy-Item -LiteralPath $script:RegistryPath -Destination (Join-Path -Path (Join-Path -Path $script:Sandbox 'src\modules\configs') -ChildPath 'harness-filters.json') -Force }
  }

  It 'denies a plain delete when settings.unproven is deny' {
    Set-FilterRegistry -Root $script:Sandbox -Document '{"filters":[{"enabled":true,"id":"safe-delete","settings":{"unproven":"deny"}}]}'
    try {
      $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"command":"rm x"}'
      $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
      $document['hookSpecificOutput']['permissionDecision'] | Should -Be 'deny'
      $document['hookSpecificOutput']['permissionDecisionReason'] | Should -Match 'unproven-redirect'
    }
    finally { Copy-Item -LiteralPath $script:RegistryPath -Destination (Join-Path -Path (Join-Path -Path $script:Sandbox 'src\modules\configs') -ChildPath 'harness-filters.json') -Force }
  }

  It 'denies an uppercase settings.unproven value (guard: the fold stops above the setting)' {
    Set-FilterRegistry -Root $script:Sandbox -Document '{"filters":[{"enabled":true,"id":"safe-delete","settings":{"unproven":"Allow"}}]}'
    try {
      $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"command":"rm x"}'
      $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
      $document['hookSpecificOutput']['permissionDecision'] | Should -Be 'deny'
      $document['hookSpecificOutput']['permissionDecisionReason'] | Should -Match 'unproven-redirect'
    }
    finally { Copy-Item -LiteralPath $script:RegistryPath -Destination (Join-Path -Path (Join-Path -Path $script:Sandbox 'src\modules\configs') -ChildPath 'harness-filters.json') -Force }
  }

  It 'denies an unknown settings.unproven value and names every schema-accepted word' {
    # WHY the words come from the schema: the fallthrough message is the only place
    # an operator is told them, so a value added to the enum alone fails here rather
    # than shipping unannounced. The POSIX twin reads the same enum.
    Set-FilterRegistry -Root $script:Sandbox -Document '{"filters":[{"enabled":true,"id":"safe-delete","settings":{"unproven":"maybe"}}]}'
    try {
      $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"command":"rm x"}'
      $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
      $document['hookSpecificOutput']['permissionDecision'] | Should -Be 'deny'
      $document['hookSpecificOutput']['permissionDecisionReason'] | Should -Match 'unproven-redirect'
      # An empty enum would make the loop below vacuous, so the count is asserted.
      $schema = Get-Content -Raw -LiteralPath $script:SchemaPath | ConvertFrom-Json
      $words = @($schema.properties.filters.items.allOf[0].then.properties.settings.properties.unproven.enum)
      $words.Count | Should -BeGreaterOrEqual 1
      foreach ($word in $words) {
        $document['hookSpecificOutput']['permissionDecisionReason'] | Should -Match ([regex]::Escape($word))
      }
    }
    finally { Copy-Item -LiteralPath $script:RegistryPath -Destination (Join-Path -Path (Join-Path -Path $script:Sandbox 'src\modules\configs') -ChildPath 'harness-filters.json') -Force }
  }

  It 'denies every bypass family' {
    $cases = @(
      @{ Payload = '{"command":"/bin/rm -rf x"}'; Rule = 'native-path' }
      @{ Payload = '{"command":"./rm x"}'; Rule = 'native-path' }
      @{ Payload = '{"command":"C:/BIN/RM.exe -r x"}'; Rule = 'native-path' }
      @{ Payload = '{"command":"C:\\BIN\\RM.exe -r x"}'; Rule = 'native-path' }
      @{ Payload = '{"command":"cmd.exe /c del x"}'; Rule = 'cmd-shell' }
    )
    foreach ($case in $cases) {
      $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload $case.Payload
      $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
      # A Windows drive path is a native deletion only on Windows. The POSIX
      # filter reads it as an ordinary word, so the rule there is no-match.
      if (-not $IsWindows -and $case.Payload -match 'C:') {
        $document['hookSpecificOutput']['permissionDecision'] | Should -Be 'allow'
        $document['hookSpecificOutput']['permissionDecisionReason'] | Should -Match 'no-match'
        continue
      }
      $document['hookSpecificOutput']['permissionDecision'] | Should -Be 'deny'
      $document['hookSpecificOutput']['permissionDecisionReason'] | Should -Match ([regex]::Escape("($($case.Rule))"))
    }
  }

  It 'classifies an escaped deletion word according to platform path semantics' {
    # WHY: on Windows a backslash is a path separator, so `\rm` is a native-path
    # deletion and must be denied. On POSIX a leading backslash escapes the word
    # name, so the word still resolves through PATH and the redirect proof decides;
    # the host may prove or not prove that redirect, but it is never a native-path
    # denial.
    foreach ($payload in @('{"command":"\\rm x"}', '{"command":"\\RM -Recurse x"}')) {
      $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload $payload
      $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
      $decision = $document['hookSpecificOutput']['permissionDecision']
      $reason = $document['hookSpecificOutput']['permissionDecisionReason']
      if ($IsWindows) {
        $decision | Should -Be 'deny'
        $reason | Should -Match 'native-path'
      }
      else {
        $decision | Should -Not -Be 'deny'
        $reason | Should -Match 'redirect'
      }
    }
  }
}

Describe 'safe-delete deletion-verb case matching' {
  # WHY uppercase: PowerShell folds case for every deletion word, so `DEL` is the
  # same deletion as `del`; a case-sensitive verb test would let it through as
  # no-match with no proof ruling. The case fails if the verb test stops folding
  # case, which is exactly the regression it exists for.
  It 'proves an uppercase deletion word through the managed profile' {
    $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"command":"DEL /S x"}' -HomePath $script:FilterProfileHome

    $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
    $document['hookSpecificOutput']['permissionDecision'] | Should -Be 'allow'
    $document['hookSpecificOutput']['permissionDecisionReason'] | Should -Match 'proven-redirect'
  }

  It 'proves Remove-Item spelled in lower case through the managed profile' {
    $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"command":"remove-item -Recurse -Force C:\\data"}' -HomePath $script:FilterLowerProfileHome

    $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
    $document['hookSpecificOutput']['permissionDecision'] | Should -Be 'allow'
    $document['hookSpecificOutput']['permissionDecisionReason'] | Should -Match 'proven-redirect'
  }

  It 'answers unproven for a session started with -NoProfile' {
    # WHY: -NoProfile discards the managed profile, so the redirect a profile word
    # relies on is not loaded. No shim manifest is deployed here, and the default
    # settings.unproven is ask, so the answer is unproven and not a denial.
    $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"command":"pwsh -NoProfile -c \"Remove-Item x\""}'

    $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
    $document['hookSpecificOutput']['permissionDecision'] | Should -Not -Be 'deny'
    $document['hookSpecificOutput']['permissionDecisionReason'] | Should -Match 'unproven-redirect'
  }
}

Describe 'aggregation and filter failure' {
  It 'ranks deny above ask above allow in any registry order' {
    Add-FilterScript -Root $script:Sandbox -Id 'allow-all' -Body 'console.log("allow\tno-match\tfirst");'
    Add-FilterScript -Root $script:Sandbox -Id 'ask-all' -Body 'console.log("ask\tunproven-redirect\tsecond");'
    Add-FilterScript -Root $script:Sandbox -Id 'deny-all' -Body 'console.log("deny\tnative-path\tthird");'

    foreach ($order in @(
        '{"filters":[{"enabled":true,"id":"allow-all","settings":{}},{"enabled":true,"id":"ask-all","settings":{}},{"enabled":true,"id":"deny-all","settings":{}}]}',
        '{"filters":[{"enabled":true,"id":"deny-all","settings":{}},{"enabled":true,"id":"ask-all","settings":{}},{"enabled":true,"id":"allow-all","settings":{}}]}'
      )) {
      Set-FilterRegistry -Root $script:Sandbox -Document $order
      $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"command":"anything"}'
      (ConvertFrom-Json -InputObject $result.Stdout -AsHashtable)['hookSpecificOutput']['permissionDecision'] | Should -Be 'deny'
    }

    Set-FilterRegistry -Root $script:Sandbox -Document '{"filters":[{"enabled":true,"id":"allow-all","settings":{}},{"enabled":true,"id":"ask-all","settings":{}}]}'
    $ask = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"command":"anything"}'
    (ConvertFrom-Json -InputObject $ask.Stdout -AsHashtable)['hookSpecificOutput']['permissionDecision'] | Should -Be 'ask'
  }

  It 'skips a disabled registry entry' {
    Set-FilterRegistry -Root $script:Sandbox -Document '{"filters":[{"enabled":false,"id":"deny-all","settings":{}},{"enabled":true,"id":"allow-all","settings":{}}]}'
    $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"command":"anything"}'

    (ConvertFrom-Json -InputObject $result.Stdout -AsHashtable)['hookSpecificOutput']['permissionDecision'] | Should -Be 'allow'
  }

  It 'records a crashing filter as filter-error' {
    Add-FilterScript -Root $script:Sandbox -Id 'crash' -Body 'console.error("boom"); process.exit(3);'
    Set-FilterRegistry -Root $script:Sandbox -Document '{"filters":[{"enabled":true,"id":"crash","settings":{}}]}'
    $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"command":"anything"}'

    $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
    $document['hookSpecificOutput']['permissionDecision'] | Should -Be 'ask'
    $document['hookSpecificOutput']['permissionDecisionReason'] | Should -Match 'filter-error'
  }

  It 'records a missing filter script as filter-error' {
    Set-FilterRegistry -Root $script:Sandbox -Document '{"filters":[{"enabled":true,"id":"absent","settings":{}}]}'
    $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"command":"anything"}'

    $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
    $document['hookSpecificOutput']['permissionDecision'] | Should -Be 'ask'
    $document['hookSpecificOutput']['permissionDecisionReason'] | Should -Match 'filter-error'
  }

  It 'answers ask when no filter decides' {
    Set-FilterRegistry -Root $script:Sandbox -Document '{"filters":[{"enabled":false,"id":"safe-delete","settings":{}}]}'
    try {
      $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"command":"ls -la"}'

      $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
      $document['hookSpecificOutput']['permissionDecision'] | Should -Be 'ask'
      $document['hookSpecificOutput']['permissionDecisionReason'] | Should -Match 'no-filter'
    }
    finally { Copy-Item -LiteralPath $script:RegistryPath -Destination (Join-Path -Path (Join-Path -Path $script:Sandbox 'src\modules\configs') -ChildPath 'harness-filters.json') -Force }
  }

  It 'reads an uppercase decision as ask, not allow' {
    # WHY: -in folds case, so without -cnotin the uppercase decision would survive
    # normalization and then lose the case-sensitive rank lookup, which reads as
    # allow. The POSIX twin answers ask for the same bytes.
    Add-FilterScript -Root $script:Sandbox -Id 'upper' -Body 'console.log("DENY\tsome-rule\tuppercase");'
    Set-FilterRegistry -Root $script:Sandbox -Document '{"filters":[{"enabled":true,"id":"upper","settings":{}}]}'
    $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"command":"anything"}'

    (ConvertFrom-Json -InputObject $result.Stdout -AsHashtable)['hookSpecificOutput']['permissionDecision'] | Should -Be 'ask'
  }

  It 'keeps a filter diagnostic off the verdict path' {
    # WHY: the verdict is the single stdout line. A stderr diagnostic that happens
    # to look like a protocol line must not become the answer.
    Add-FilterScript -Root $script:Sandbox -Id 'noisy' -Body 'console.log("allow\tno-match\tquiet"); console.error("ask\tunproven-redirect\tstderr");'
    Set-FilterRegistry -Root $script:Sandbox -Document '{"filters":[{"enabled":true,"id":"noisy","settings":{}}]}'
    $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"command":"anything"}'

    (ConvertFrom-Json -InputObject $result.Stdout -AsHashtable)['hookSpecificOutput']['permissionDecision'] | Should -Be 'allow'
  }

  It 'answers ask with filter-error when a filter prints a second line' {
    # WHY: exactly one stdout line is the verdict. A filter that prints a
    # decision and a second line, which a harness reading the whole stdout or
    # its last line could take as another answer, has stated no verdict, so the
    # runner falls back to ask and names filter-error, the document the POSIX
    # twin prints for the same bytes.
    Add-FilterScript -Root $script:Sandbox -Id 'twoline' -Body 'console.log("allow\tno-match\tquiet"); console.log("garbage");'
    Set-FilterRegistry -Root $script:Sandbox -Document '{"filters":[{"enabled":true,"id":"twoline","settings":{}}]}'
    $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"command":"anything"}'

    $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
    $document['hookSpecificOutput']['permissionDecision'] | Should -Be 'ask'
    $document['hookSpecificOutput']['permissionDecisionReason'] | Should -Match 'filter-error'
  }

  It 'reads a blank line ahead of the verdict as one verdict' {
    # WHY: the POSIX twin drops empty lines before it counts, so a blank line
    # ahead of the verdict is not content on either platform. Counting raw lines
    # here would answer filter-error for bytes the POSIX twin accepts.
    Add-FilterScript -Root $script:Sandbox -Id 'blankfirst' -Body 'console.log(""); console.log("allow\tno-match\tquiet");'
    Set-FilterRegistry -Root $script:Sandbox -Document '{"filters":[{"enabled":true,"id":"blankfirst","settings":{}}]}'
    $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"command":"anything"}'

    $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
    $document['hookSpecificOutput']['permissionDecision'] | Should -Be 'allow'
    $document['hookSpecificOutput']['permissionDecisionReason'] | Should -Match 'no-match'
  }
}
