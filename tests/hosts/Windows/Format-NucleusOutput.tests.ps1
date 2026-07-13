<#
.SYNOPSIS
  Pester tests for Format-NucleusOutput.psm1 output formatting functions.

.DESCRIPTION
  Tests Get-NucleusCommandName, Write-NucleusInfo, Write-NucleusError,
  Write-NucleusWarning, Write-NucleusDryRun, and Write-NucleusDone
  by importing the module directly.

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/hosts/Windows/Format-NucleusOutput.tests.ps1 -Passthru"
#>

BeforeAll {
  $modulePath = Join-Path $PSScriptRoot '../../../src/hosts/Windows/modules/Format-NucleusOutput.psm1'
  # WHY: cleanup — module may not be loaded.
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
}

Describe 'Write-NucleusError' {
  It 'outputs formatted error message' {
    $result = Write-NucleusError 'something failed' 2>&1
    $result | Should -Match ': error: something failed$'
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
