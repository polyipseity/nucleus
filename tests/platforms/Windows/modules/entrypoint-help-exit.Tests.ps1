<#
.SYNOPSIS
  Pester tests for the help and missing-action exit contract of the two
  Windows entry-point scripts that have a POSIX twin with no PATH entry.

.DESCRIPTION
  Two things are pinned for each script. A bare invocation exits 1 with a
  located error on stderr and nothing on stdout, which is what autostart.sh
  and menu-bar.sh do. -Help on its own exits 0 and writes help, because naming
  an action is not a precondition for asking what the actions are.

  Each case runs the real script in a child pwsh rather than dot-sourcing it.
  The exit code and the two streams are the contract under test, and
  dot-sourcing collapses both: an exit inside a dot-sourced script ends the
  caller, and in-process Write-Error does not split the streams the way a
  console host does.

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/entrypoint-help-exit.Tests.ps1 -Passthru"
#>

BeforeAll {
  # check-suppress:suppression_doc: deterministic color state -- color init runs
  # at import; NO_COLOR pins NucleusColorOn=false for the whole suite so the
  # captured error line is a plain string.
  $env:NO_COLOR = '1'

  $Script:PwshExe = (Get-Command pwsh).Source
  $Script:RepoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..')).Path
  $Script:AutostartScript = Join-Path -Path $Script:RepoRoot -ChildPath 'src\scripts\autostart.ps1'
  $Script:MenuBarScript = Join-Path -Path $Script:RepoRoot -ChildPath 'src\scripts\menu-bar.ps1'

  function Invoke-EntryPoint {
    param(
      [Parameter(Mandatory)]
      [string]$ScriptPath,

      [string[]]$Arguments = @()
    )
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Script:PwshExe
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-File', $ScriptPath) + $Arguments) {
      $startInfo.ArgumentList.Add($argument)
    }
    $process = [System.Diagnostics.Process]::Start($startInfo)
    # WHY: both streams are read asynchronously; reading one to the end while the
    # child fills the other stream's buffer can deadlock.
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    return [pscustomobject]@{
      Stdout   = $stdout.Result
      Stderr   = ConvertTo-FlatText $stderr.Result
      ExitCode = $process.ExitCode
    }
  }

  function ConvertTo-FlatText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    # WHY: a console host renders Write-Error across several gutter-prefixed
    # lines and wraps the message at the terminal width, so a multi-token
    # assertion matches only against flattened text. Flattening is what keeps
    # that assertion from moving with the width.
    return (($Text -replace '\r?\n', ' ') -replace '\s*\|\s*', ' ' -replace '\s+', ' ').Trim()
  }
}

Describe 'autostart.ps1 entry contract' {
  It 'exits 1, errors on stderr, and leaves stdout empty when no action is given' {
    $result = Invoke-EntryPoint -ScriptPath $Script:AutostartScript
    $result.ExitCode | Should -Be 1
    $result.Stdout | Should -BeNullOrEmpty
    $result.Stderr | Should -Match 'error: missing action \(list, status, enable, disable, apply, verify\)'
  }

  It 'exits 0 and writes help when -Help is given' {
    $result = Invoke-EntryPoint -ScriptPath $Script:AutostartScript -Arguments @('-Help')
    $result.ExitCode | Should -Be 0
    $result.Stdout | Should -Match 'Unified GUI/user app auto-start management'
    $result.Stderr | Should -Not -Match 'missing action'
  }

}

Describe 'menu-bar.ps1 entry contract' {
  It 'exits 1, errors on stderr, and leaves stdout empty when no action is given' {
    $result = Invoke-EntryPoint -ScriptPath $Script:MenuBarScript
    $result.ExitCode | Should -Be 1
    $result.Stdout | Should -BeNullOrEmpty
    $result.Stderr | Should -Match 'error: missing action \(list, status, show, hide, apply, verify\)'
  }

  It 'exits 0 and writes help when -Help is given' {
    $result = Invoke-EntryPoint -ScriptPath $Script:MenuBarScript -Arguments @('-Help')
    $result.ExitCode | Should -Be 0
    $result.Stdout | Should -Match 'Unified menu-bar / tray icon visibility management'
    $result.Stderr | Should -Not -Match 'missing action'
  }

}
