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
    [CmdletBinding(SupportsShouldProcess = $true)]
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
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
      [Parameter(Mandatory)]
      [string]$Root,

      [Parameter(Mandatory)]
      [string]$Harness,

      [Parameter(Mandatory)]
      [string]$Payload
    )

    $previous = $env:NUCLEUS_REPO_ROOT
    $env:NUCLEUS_REPO_ROOT = $Root
    try {
      $runner = Join-Path -Path (Join-Path -Path $Root 'src\scripts\notify') -ChildPath 'harness-filter.ps1'
      $stdout = @($Payload | & $script:PwshPath -NoProfile -File $runner $Harness 2>$null) -join "`n"
      return @{ ExitCode = $LASTEXITCODE; Stdout = $stdout }
    }
    finally { $env:NUCLEUS_REPO_ROOT = $previous }
  }

  $script:Sandbox = New-FilterSandbox
}

AfterAll {
  Remove-FilterSandbox -Root $script:Sandbox
}

Describe 'harness-filter render table' {
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

  It 'asks about a plain delete with the unproven-redirect rule' {
    $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"command":"rm x"}'

    $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
    $document['hookSpecificOutput']['permissionDecision'] | Should -Be 'ask'
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

  It 'allows a payload that carries no shell command' {
    $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"tool_name":"readFile","tool_input":{"path":"x"}}'

    $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
    $document['hookSpecificOutput']['permissionDecision'] | Should -Be 'allow'
    $document['hookSpecificOutput']['permissionDecisionReason'] | Should -Match 'not-a-command'
  }
}

Describe 'safe-delete filter settings' {
  It 'allows a plain delete when settings.unproven is allow' {
    Set-FilterRegistry -Root $script:Sandbox -Document '{"filters":[{"enabled":true,"id":"safe-delete","settings":{"unproven":"allow"}}]}'
    try {
      $result = Invoke-FilterTwin -Root $script:Sandbox -Harness 'copilot' -Payload '{"command":"rm x"}'
      $document = ConvertFrom-Json -InputObject $result.Stdout -AsHashtable
      $document['hookSpecificOutput']['permissionDecision'] | Should -Be 'allow'
    }
    finally { Copy-Item -LiteralPath $script:RegistryPath -Destination (Join-Path -Path (Join-Path -Path $script:Sandbox 'src\modules\configs') -ChildPath 'harness-filters.json') -Force }
  }

  It 'denies every bypass family' {
    $cases = @(
      @{ Payload = '{"command":"/bin/rm -rf x"}'; Rule = 'native-path' }
      @{ Payload = '{"command":"./rm x"}'; Rule = 'native-path' }
      @{ Payload = '{"command":"\\rm x"}'; Rule = 'escaped-spelling' }
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
}
