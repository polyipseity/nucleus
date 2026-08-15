<#
.SYNOPSIS
  Pester tests for Format-NucleusOutput.psm1 output formatting functions.

.DESCRIPTION
  Tests Get-NucleusCommandName, Write-NucleusInfo, Write-NucleusError,
  Write-NucleusWarning, Write-NucleusDryRun, and Write-NucleusDone
  by importing the module directly.

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/hosts/Windows/Format-NucleusOutput.Tests.ps1 -Passthru"
#>

BeforeAll {
  # check-suppress:suppression_doc: deterministic color state -- color init runs
  # at import; NO_COLOR pins NucleusColorOn=false for the whole suite (captured
  # pure strings retain ANSI regardless of OutputRendering, so capture-time
  # stripping cannot be relied on).
  $env:NO_COLOR = '1'
  $modulePath = Join-Path $PSScriptRoot '../../../../src/platforms/Windows/modules/Format-NucleusOutput.psm1'
  # check-suppress:suppression_doc: cleanup -- module may not be loaded; WHY: Remove-Module gracefully handles absence.
  Remove-Module Format-NucleusOutput -ErrorAction SilentlyContinue
  Import-Module $modulePath -Force -DisableNameChecking
}

Describe 'Get-NucleusCommandName' {
  It 'derives command name from nucleus-* path' {
    $result = Get-NucleusCommandName -Path '/some/bin/nucleus-health-check.ps1'
    $result | Should -Be 'health-check'
  }

  It 'derives from nucleus- prefix' {
    $result = Get-NucleusCommandName -Path '/some/bin/nucleus-bump-lockfile.ps1'
    $result | Should -Be 'bump-lockfile'
  }

  It 'handles script without nucleus- prefix' {
    $result = Get-NucleusCommandName -Path '/some/bin/myscript.ps1'
    $result | Should -Be 'myscript'
  }

  It 'handles script without .ps1 extension' {
    $result = Get-NucleusCommandName -Path '/some/bin/nucleus-svc'
    $result | Should -Be 'svc'
  }
}

Describe 'Write-NucleusInfo' {
  It 'outputs formatted info message' {
    $result = Write-NucleusInfo 'hello world' 6>&1
    $result | Should -Match ': hello world$'
  }

  It 'outputs with command name prefix' {
    $result = Write-NucleusInfo 'test' 6>&1
    # Should start with a word (the command name) followed by ": "
    $result | Should -Match '^[a-zA-Z][a-zA-Z0-9-]*: test$'
  }

  It 'honors -CommandName label override (F1)' {
    $result = Write-NucleusInfo 'hi' -CommandName cursor 6>&1
    $result | Should -BeExactly 'cursor: hi'
  }

  It 'emits no ESC bytes under NO_COLOR' {
    $result = Write-NucleusInfo 'plain' 6>&1
    $result | Should -Not -Match "`e"
  }

  It 'forces ESC bytes when FORCE_COLOR=1 even when captured' {
    # NO_COLOR wins over FORCE_COLOR, so it must be removed first
    Remove-Item Env:NO_COLOR -ErrorAction SilentlyContinue
    $env:FORCE_COLOR = '1'
    Remove-Module Format-NucleusOutput -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force -DisableNameChecking
    $result = Write-NucleusInfo 'colored' 6>&1
    $result | Should -Match "`e"
    # restore deterministic state for the rest of the suite
    Remove-Item Env:FORCE_COLOR -ErrorAction SilentlyContinue
    $env:NO_COLOR = '1'
    Remove-Module Format-NucleusOutput -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force -DisableNameChecking
  }
}

Describe 'Write-NucleusError' {
  It 'outputs formatted error message' {
    $result = Write-NucleusError 'something failed' 2>&1
    $result | Should -Match ': error: something failed$'
  }

  It 'is non-terminating with -ErrorAction Continue under Stop' {
    $previous = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Stop'
      $result = Write-NucleusError 'non-fatal' -ErrorAction Continue 2>&1
      $result | Should -Match ': error: non-fatal$'
    }
    finally {
      $ErrorActionPreference = $previous
    }
  }

  It 'terminates under Stop by default (flagless)' {
    # Pester's test session state isolates the It block's $ErrorActionPreference
    # from Import-Module'd module functions (module scope sees Continue), so the
    # ambient-termination contract is verified in a child pwsh at console scope,
    # mirroring production wiring where apply.ps1 dot-sources the module under
    # $ErrorActionPreference = 'Stop'.
    $script = @"
`$ErrorActionPreference = 'Stop'
Import-Module '$modulePath' -Force -DisableNameChecking
try {
  Write-NucleusError 'fatal'
  exit 1
} catch {
  exit 0
}
"@
    pwsh -NoProfile -Command $script | Out-Null
    $LASTEXITCODE | Should -Be 0
  }
}

Describe 'Write-NucleusWarning' {
  It 'outputs formatted warning message' {
    $result = Write-NucleusWarning 'beware' 3>&1
    $result | Should -Match ': warning: beware$'
  }
}

Describe 'Write-NucleusDryRun' {
  It 'outputs dry-run message' {
    $result = Write-NucleusDryRun 'would do x' 6>&1
    $result | Should -Match ': \[dry-run\] would do x$'
  }
}

Describe 'Write-NucleusDone' {
  It 'outputs done message' {
    $result = Write-NucleusDone 6>&1
    $result | Should -Match ': done$'
  }
}

Describe 'Write-NucleusNotice' {
  It 'outputs notice message' {
    $result = Write-NucleusNotice 'reboot pending' 6>&1
    $result | Should -Match ': \[notice\] reboot pending$'
  }

  It 'honors -CommandName label override (F1)' {
    $result = Write-NucleusNotice 'reboot' -CommandName apply 6>&1
    $result | Should -BeExactly 'apply: [notice] reboot'
  }

  It 'emits no ESC bytes under NO_COLOR' {
    $result = Write-NucleusNotice 'plain' 6>&1
    $result | Should -Not -Match "`e"
  }
}

Describe 'Semantic message coloring' {
  # Color-on branch: FORCE_COLOR=1 overrides capture-time suppression, so the
  # tokenizer output (ESC-wrapped spans) is observable in Pester.
  BeforeAll {
    Remove-Item Env:NO_COLOR -ErrorAction SilentlyContinue
    $env:FORCE_COLOR = '1'
    Remove-Module Format-NucleusOutput -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force -DisableNameChecking
  }
  AfterAll {
    Remove-Item Env:FORCE_COLOR -ErrorAction SilentlyContinue
    $env:NO_COLOR = '1'
    Remove-Module Format-NucleusOutput -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force -DisableNameChecking
  }

  It 'wraps single-quoted spans in blue when color is on' {
    $result = (Write-NucleusInfo "account 'jellyfin'" 6>&1) -join "`n"
    $result.Contains("`e[34m'jellyfin'`e[0m") | Should -BeTrue
  }

  It 'wraps URLs in underline cyan when color is on' {
    $result = (Write-NucleusInfo 'check https://example.com/x' 6>&1) -join "`n"
    $result.Contains("`e[4m`e[36mhttps://example.com/x`e[0m") | Should -BeTrue
  }

  It 'colors URLs inside quoted spans (quote pass runs first)' {
    $result = (Write-NucleusInfo "see 'https://example.com' now" 6>&1) -join "`n"
    # URL wrap resets style within the span, so the closing quote renders plain
    # (mirrors the POSIX _nuc_semantic_color pass ordering).
    $result.Contains("`e[34m'`e[4m`e[36mhttps://example.com`e[0m'`e[0m") | Should -BeTrue
  }

  It 'colors notice messages too' {
    $result = (Write-NucleusNotice 'install from https://example.com' 6>&1) -join "`n"
    $result.Contains("`e[4m`e[36mhttps://example.com`e[0m") | Should -BeTrue
  }

  It 'is byte-identical to plain text under NO_COLOR' {
    Remove-Item Env:FORCE_COLOR -ErrorAction SilentlyContinue
    $env:NO_COLOR = '1'
    Remove-Module Format-NucleusOutput -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force -DisableNameChecking
    $result = Write-NucleusInfo "account 'jellyfin' at https://example.com" 6>&1
    $result | Should -Match "^[a-zA-Z][a-zA-Z0-9-]*: account 'jellyfin' at https://example.com$"
    Remove-Item Env:NO_COLOR -ErrorAction SilentlyContinue
    $env:FORCE_COLOR = '1'
    Remove-Module Format-NucleusOutput -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force -DisableNameChecking
  }
}

Describe 'Color detection branches' {
  It 'forces ESC bytes when CLICOLOR_FORCE is set' {
    Remove-Item Env:NO_COLOR -ErrorAction SilentlyContinue
    $env:CLICOLOR_FORCE = '1'
    Remove-Module Format-NucleusOutput -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force -DisableNameChecking
    $result = Write-NucleusInfo 'colored' 6>&1
    $result | Should -Match "`e"
    Remove-Item Env:CLICOLOR_FORCE -ErrorAction SilentlyContinue
    $env:NO_COLOR = '1'
    Remove-Module Format-NucleusOutput -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force -DisableNameChecking
  }

  It 'does not force color when FORCE_COLOR=0' {
    Remove-Item Env:NO_COLOR -ErrorAction SilentlyContinue
    $env:FORCE_COLOR = '0'
    Remove-Module Format-NucleusOutput -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force -DisableNameChecking
    $result = Write-NucleusInfo 'plain' 6>&1
    $result | Should -Not -Match "`e"
    Remove-Item Env:FORCE_COLOR -ErrorAction SilentlyContinue
    $env:NO_COLOR = '1'
    Remove-Module Format-NucleusOutput -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force -DisableNameChecking
  }
}
