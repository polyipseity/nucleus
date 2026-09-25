<#
.SYNOPSIS
  Wiring test: the Windows apply path must invoke the apply-time health re-arm.

.DESCRIPTION
  Health-ClearAll is defined and unit-tested, but a defined-and-tested function is
  not a wired one.  The defect this guards against was that the re-arm had NO
  production call site, so a blocked instance survived apply and cleared only on
  reboot — while two separate comments (service-watchdog.ps1:18 and
  ServiceHealth.ps1:40) asserted that apply cleared it.

  The Windows SCM/Task Scheduler runtime cannot be exercised from this host, so the
  call site is proven by parsing apply.ps1 and asserting the invocation is present
  and UNCONDITIONAL.  A re-arm behind a flag or an if-block would leave the default
  apply path exactly as broken as having no call at all.

  The file is parsed rather than grepped so that a commented-out line or a string
  literal mentioning the name can never satisfy the test.

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/apply-health-rearm.Tests.ps1 -Output Detailed"
#>

BeforeAll {
  $script:ApplyPath = Join-Path $PSScriptRoot '../../../../src/hosts/Windows/apply.ps1'

  $tokens = $null
  $errors = $null
  $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ApplyPath, [ref]$tokens, [ref]$errors)
  $script:ParseErrors = @($errors)

  # Every actual command invocation of Health-ClearAll.  A comment or a string
  # mentioning the name produces no CommandAst, so neither can satisfy this.
  $script:Invocations = @(
    $script:Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
      Where-Object { $_.GetCommandName() -eq 'Health-ClearAll' }
  )

  # An invocation is conditional when a guard encloses it.
  $script:Conditional = @(
    foreach ($command in $script:Invocations) {
      $ancestor = $command.Parent
      while ($ancestor) {
        if ($ancestor -is [System.Management.Automation.Language.IfStatementAst] -or
            $ancestor -is [System.Management.Automation.Language.SwitchStatementAst]) {
          $command
          break
        }
        $ancestor = $ancestor.Parent
      }
    }
  )
}

Describe 'apply.ps1 wires the apply-time health re-arm' {
  It 'parses apply.ps1 without errors' {
    $script:ParseErrors.Count | Should -Be 0
  }

  It 'invokes Health-ClearAll' {
    $script:Invocations.Count | Should -BeGreaterThan 0 -Because 'a defined-and-tested function with no call site is exactly the defect this guards'
  }

  It 'invokes Health-ClearAll unconditionally' {
    $unconditional = $script:Invocations.Count - $script:Conditional.Count
    $unconditional | Should -BeGreaterThan 0 -Because 'a re-arm inside a guard leaves the default apply path as broken as having no call at all'
  }
}
