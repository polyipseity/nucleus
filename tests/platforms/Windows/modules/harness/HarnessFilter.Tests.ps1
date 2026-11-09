<#
.SYNOPSIS
  Pester coverage for the Windows harness decision runner and its filter.

.DESCRIPTION
  Covers the twin of harness-filter.sh: the render table (Cursor and Copilot
  documents, plain word for the rest), the safe-delete filter's rule families and
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
  $script:PwshPath = [Environment]::ProcessPath

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

    foreach ($name in @('harness-bridge-common', 'harness-filter')) {
      Copy-Item -LiteralPath (Join-Path -Path $script:NotifyDir -ChildPath "$name.ps1") -Destination (Join-Path -Path $notifyCopy -ChildPath "$name.ps1")
    }
    foreach ($filter in @(Get-ChildItem -LiteralPath $script:FiltersDir -File -Filter '*.ps1')) {
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
    return $root
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

  function Add-FilterScript {
    <#
    .SYNOPSIS
      Adds a synthetic filter beside the real ones.
    .PARAMETER Root
      Fixture root directory.
    .PARAMETER Id
      Filter id the registry names.
    .PARAMETER Body
      Script body, which prints the protocol line.
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

    $path = Join-Path -Path (Join-Path -Path $Root 'src\scripts\notify\filters') -ChildPath "$Id.ps1"
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
    .PARAMETER UserProfile
      Overrides USERPROFILE for the child, so a case decides which shim directory the filter
      compares against.
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

      [string]$UserProfile = ''
    )

    $previous = $env:NUCLEUS_REPO_ROOT
    $previousLogDir = $env:NUCLEUS_LOG_DIR
    $previousUserProfile = $env:USERPROFILE
    $env:NUCLEUS_REPO_ROOT = $Root
    $env:NUCLEUS_LOG_DIR = Join-Path -Path $Root 'logs'
    if (-not [string]::IsNullOrEmpty($UserProfile)) { $env:USERPROFILE = $UserProfile }
    try {
      $runner = Join-Path -Path (Join-Path -Path $Root 'src\scripts\notify') -ChildPath 'harness-filter.ps1'
      $stdout = @($Payload | & $script:PwshPath -NoProfile -File $runner $Harness 2>$null) -join "`n"
      return @{ ExitCode = $LASTEXITCODE; Stdout = $stdout }
    }
    finally {
      $env:NUCLEUS_REPO_ROOT = $previous
      $env:NUCLEUS_LOG_DIR = $previousLogDir
      $env:USERPROFILE = $previousUserProfile
    }
  }

  $script:Sandbox = New-FilterSandbox

  # A profile with no shims, so a plain delete reads as unproven whatever the
  # developer's own USERPROFILE carries.
  $script:UnprovenProfile = Join-Path -Path $script:Sandbox 'unproven-profile'
  $null = New-Item -ItemType Directory -Path (Join-Path -Path $script:UnprovenProfile -ChildPath '.local\bin') -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
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

  It 'denies a plain delete whose redirect is unproven' {
    $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"command":"rm x"}' -UserProfile $script:UnprovenProfile

    $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
    $document['hookSpecificOutput']['permissionDecision'] | Should -Be 'deny'
    $document['hookSpecificOutput']['permissionDecisionReason'] | Should -Match 'unproven-redirect'
  }

  It 'prints the plain word for pi, codex, and an unknown harness' {
    foreach ($harness in @('pi', 'codex', 'unknown-harness')) {
      $result = Invoke-FilterTwin -Root $script:Sandbox -Harness $harness -Payload '{"command":"/bin/rm x"}'
      $result.Stdout | Should -Be 'deny'
    }
  }

  It 'allows a command no filter matches' {
    $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'opencode' -Payload '{"command":"ls -la"}'

    $result.Stdout | Should -Be 'allow'
  }

  It 'asks for a payload that carries no shell command' {
    $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"tool_name":"readFile","tool_input":{"path":"x"}}'

    $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
    $document['hookSpecificOutput']['permissionDecision'] | Should -Be 'ask'
    $document['hookSpecificOutput']['permissionDecisionReason'] | Should -Match 'not-a-command'
  }
}

Describe 'safe-delete filter settings' {
  It 'allows a plain delete when settings.unproven is allow' {
    Set-FilterRegistry -Root $script:Sandbox -Document '{"filters":[{"enabled":true,"id":"safe-delete","settings":{"unproven":"allow"}}]}'
    try {
      $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"command":"rm x"}' -UserProfile $script:UnprovenProfile
      $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
      $document['hookSpecificOutput']['permissionDecision'] | Should -Be 'allow'
      $document['hookSpecificOutput']['permissionDecisionReason'] | Should -Match 'unproven-redirect'
    }
    finally { Copy-Item -LiteralPath $script:RegistryPath -Destination (Join-Path -Path (Join-Path -Path $script:Sandbox 'src\modules\configs') -ChildPath 'harness-filters.json') -Force }
  }

  It 'routes a plain delete to the approval sources when settings.unproven is route' {
    Set-FilterRegistry -Root $script:Sandbox -Document '{"filters":[{"enabled":true,"id":"safe-delete","settings":{"unproven":"route"}}]}'
    try {
      $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"command":"rm x"}' -UserProfile $script:UnprovenProfile
      $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
      $document['hookSpecificOutput']['permissionDecision'] | Should -Be 'ask'
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

  It 'denies every bypass family' {
    $cases = @(
      @{ Payload = '{"command":"/bin/rm -rf x"}'; Rule = 'native-path' }
      @{ Payload = '{"command":"./rm x"}'; Rule = 'native-path' }
      @{ Payload = '{"command":"\\rm x"}'; Rule = 'escaped-spelling' }
      # WHY these three: the verb test folds case, so an uppercase word is a
      # deletion, and a fold that stops at the verb lets the uppercase spelling
      # slip the families and answer no-match, which reads as allow. The first two
      # fail that way before the families fold. The third is a guard rather than a
      # red-before case: `-like` already folded case here, and a Windows backslash
      # path is caught by the escaped family, which is why it names that rule.
      @{ Payload = '{"command":"\\RM -Recurse x"}'; Rule = 'escaped-spelling' }
      @{ Payload = '{"command":"C:\\BIN\\RM.exe -r x"}'; Rule = 'escaped-spelling' }
      @{ Payload = '{"command":"C:/BIN/RM.exe -r x"}'; Rule = 'native-path' }
      @{ Payload = '{"command":"cmd.exe /c del x"}'; Rule = 'cmd-shell' }
    )
    foreach ($case in $cases) {
      $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload $case.Payload
      $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
      $document['hookSpecificOutput']['permissionDecision'] | Should -Be 'deny'
      $document['hookSpecificOutput']['permissionDecisionReason'] | Should -Match ([regex]::Escape("($($case.Rule))"))
    }
  }
}

Describe 'safe-delete redirect proof' {
  # WHY uppercase: PowerShell folds case for every deletion word, so `DEL` is the
  # same deletion as `del`; a case-sensitive verb test would let it through as
  # no-match with no unproven ruling. The case fails if the verb test stops folding
  # case, which is exactly the regression it exists for.
  It 'denies an uppercase deletion word whose redirect is unproven' {
    $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"command":"DEL /S x"}' -UserProfile $script:UnprovenProfile

    $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
    $document['hookSpecificOutput']['permissionDecision'] | Should -Be 'deny'
    $document['hookSpecificOutput']['permissionDecisionReason'] | Should -Match 'unproven-redirect'
  }

  It 'denies Remove-Item spelled in lower case' {
    $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"command":"remove-item -Recurse -Force C:\\data"}' -UserProfile $script:UnprovenProfile

    $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
    $document['hookSpecificOutput']['permissionDecision'] | Should -Be 'deny'
    $document['hookSpecificOutput']['permissionDecisionReason'] | Should -Match 'unproven-redirect'
  }
}

Describe 'aggregation and filter failure' {
  It 'ranks deny above ask above allow in any registry order' {
    Add-FilterScript -Root $script:Sandbox -Id 'allow-all' -Body 'Write-Output ("allow`tno-match`tfirst")'
    Add-FilterScript -Root $script:Sandbox -Id 'ask-all' -Body 'Write-Output ("ask`tunproven-redirect`tsecond")'
    Add-FilterScript -Root $script:Sandbox -Id 'deny-all' -Body 'Write-Output ("deny`tnative-path`tthird")'

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
    Add-FilterScript -Root $script:Sandbox -Id 'crash' -Body 'Write-Error "boom"; exit 3'
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
    Add-FilterScript -Root $script:Sandbox -Id 'upper' -Body 'Write-Output ("DENY`tsome-rule`tuppercase")'
    Set-FilterRegistry -Root $script:Sandbox -Document '{"filters":[{"enabled":true,"id":"upper","settings":{}}]}'
    $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"command":"anything"}'

    (ConvertFrom-Json -InputObject $result.Stdout -AsHashtable)['hookSpecificOutput']['permissionDecision'] | Should -Be 'ask'
  }

  It 'keeps a filter diagnostic off the verdict path' {
    # WHY: the verdict is the single stdout line. A stderr diagnostic that happens
    # to look like a protocol line must not become the answer.
    Add-FilterScript -Root $script:Sandbox -Id 'noisy' -Body 'Write-Output ("allow`tno-match`tquiet"); [Console]::Error.WriteLine("ask`tunproven-redirect`tstderr")'
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
    Add-FilterScript -Root $script:Sandbox -Id 'twoline' -Body 'Write-Output ("allow`tno-match`tquiet"); Write-Output "garbage"'
    Set-FilterRegistry -Root $script:Sandbox -Document '{"filters":[{"enabled":true,"id":"twoline","settings":{}}]}'
    $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"command":"anything"}'

    $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
    $document['hookSpecificOutput']['permissionDecision'] | Should -Be 'ask'
    $document['hookSpecificOutput']['permissionDecisionReason'] | Should -Match 'filter-error'
  }
}
