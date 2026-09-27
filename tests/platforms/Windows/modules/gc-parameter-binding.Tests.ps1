<#
.SYNOPSIS
    Pester tests for the nucleus-gc parameter block.

.DESCRIPTION
    Every no-* switch in gc.ps1 takes its default from an environment variable.
    The default has to be the boolean itself, because a switch parameter
    cannot be converted from the collection a scriptblock invocation returns.
    When the default was a scriptblock invocation, binding failed on every
    invocation and the script never reached its body, so gc was unreachable
    on Windows while its POSIX twin kept working.

    The real script cannot be run here, because a successful bind falls
    straight through to garbage collection. The test lifts the param block
    out with the AST parser and runs only that, in a child pwsh. Working on
    the block rather than on the file text keeps the assertion behavioural:
    it is the binding that is under test, not the spelling of the default.

    The switch-to-variable map is spelled out rather than derived, because
    the names do not follow a mechanical rule. NoNixGc reads NUCLEUS_GC_NO_NIX
    but NoToolCacheGc reads NUCLEUS_GC_NO_TOOL_CACHE_GC, so any transform
    wide enough to cover the second is wrong somewhere else.

    Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/gc-parameter-binding.Tests.ps1 -Passthru"
#>

BeforeAll {
    $Script:PwshExe = (Get-Command pwsh).Source
    $Script:RepoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..')).Path
    $Script:GcScript = Join-Path -Path $Script:RepoRoot -ChildPath 'scripts\gc.ps1'

    $Script:SwitchMap = @(
        [pscustomobject]@{ Switch = 'NoNixGc'; Variable = 'NUCLEUS_GC_NO_NIX' }
        [pscustomobject]@{ Switch = 'NoHmGc'; Variable = 'NUCLEUS_GC_NO_HM' }
        [pscustomobject]@{ Switch = 'NoToolCacheGc'; Variable = 'NUCLEUS_GC_NO_TOOL_CACHE_GC' }
        [pscustomobject]@{ Switch = 'NoGitCacheGc'; Variable = 'NUCLEUS_GC_NO_GIT_CACHE_GC' }
        [pscustomobject]@{ Switch = 'NoOllamaGc'; Variable = 'NUCLEUS_GC_NO_OLLAMA_GC' }
        [pscustomobject]@{ Switch = 'NoScoopGc'; Variable = 'NUCLEUS_GC_NO_SCOOP_GC' }
        [pscustomobject]@{ Switch = 'NoSccacheGc'; Variable = 'NUCLEUS_GC_NO_SCCACHE_GC' }
        [pscustomobject]@{ Switch = 'NoWallpaperGc'; Variable = 'NUCLEUS_GC_NO_WALLPAPER_GC' }
        [pscustomobject]@{ Switch = 'NoVMGc'; Variable = 'NUCLEUS_GC_NO_VM_GC' }
        [pscustomobject]@{ Switch = 'NoLogGc'; Variable = 'NUCLEUS_GC_NO_LOG_GC' }
        [pscustomobject]@{ Switch = 'NoJournaldGc'; Variable = 'NUCLEUS_GC_NO_JOURNALD_GC' }
    )

    function Get-GcParamBlock {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $Script:GcScript, [ref]$tokens, [ref]$errors)
        return $ast.ParamBlock.Extent.Text
    }

    function Invoke-ParamBlockStub {
        param(
            [Parameter(Mandatory)]
            [AllowEmptyString()]
            [string]$ParamText,

            [hashtable]$Environment = @{}
        )
        $parts = $Script:SwitchMap | ForEach-Object { '{0}=${1}' -f $_.Switch, $_.Switch }
        # WHY: the stub interpolates its own variables, so the reporting line is
        # wrapped in double quotes. [char]34 and [Environment]::NewLine rather
        # than backtick escapes, so the file carries no backtick literals at all.
        $doubleQuote = [char]34
        $stubPath = Join-Path -Path $TestDrive -ChildPath 'gc-param-stub.ps1'
        $stubText = $ParamText + [Environment]::NewLine + $doubleQuote + ($parts -join '|') + $doubleQuote
        Set-Content -Path $stubPath -Value $stubText

        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $Script:PwshExe
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.ArgumentList.Add('-NoProfile')
        $startInfo.ArgumentList.Add('-File')
        $startInfo.ArgumentList.Add($stubPath)
        foreach ($key in $Environment.Keys) {
            $startInfo.Environment[$key] = [string]$Environment[$key]
        }
        $process = [System.Diagnostics.Process]::Start($startInfo)
        # WHY: both streams are read asynchronously; reading one to the end while
        # the child fills the other stream's buffer can deadlock.
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{
            Stdout   = $stdout.Result
            Stderr   = $stderr.Result
            ExitCode = $process.ExitCode
        }
    }

    function ConvertTo-SwitchState {
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Stdout)
        $state = @{}
        foreach ($pair in ($Stdout -split '\|')) {
            $parts = $pair -split '=', 2
            if ($parts.Count -eq 2) {
                $state[$parts[0]] = [System.Convert]::ToBoolean($parts[1])
            }
        }
        return $state
    }
}

Describe 'nucleus-gc parameter block' {
    It 'binds every no-* switch to the true value of its environment variable' {
        $env = @{}
        foreach ($entry in $Script:SwitchMap) { $env[$entry.Variable] = 'true' }

        $result = Invoke-ParamBlockStub -ParamText (Get-GcParamBlock) -Environment $env
        $result.ExitCode | Should -Be 0 -Because "the block must bind; stderr was: $($result.Stderr)"

        $state = ConvertTo-SwitchState -Stdout $result.Stdout
        foreach ($entry in $Script:SwitchMap) {
            $state[$entry.Switch] | Should -BeTrue -Because "$($entry.Variable) was set to true"
        }
    }

    It 'binds every no-* switch false when its environment variable is unset' {
        $result = Invoke-ParamBlockStub -ParamText (Get-GcParamBlock)
        $result.ExitCode | Should -Be 0 -Because "the block must bind; stderr was: $($result.Stderr)"

        $state = ConvertTo-SwitchState -Stdout $result.Stdout
        foreach ($entry in $Script:SwitchMap) {
            $state.ContainsKey($entry.Switch) | Should -BeTrue -Because "the stub must report $($entry.Switch)"
            $state[$entry.Switch] | Should -BeFalse -Because "$($entry.Variable) was not set"
        }
    }

    It 'binds a switch false when its environment variable is set to anything other than true' {
        $result = Invoke-ParamBlockStub -ParamText (Get-GcParamBlock) -Environment @{ NUCLEUS_GC_NO_NIX = 'false' }
        $result.ExitCode | Should -Be 0 -Because "the block must bind; stderr was: $($result.Stderr)"

        $state = ConvertTo-SwitchState -Stdout $result.Stdout
        $state['NoNixGc'] | Should -BeFalse -Because "only the exact string true enables the switch"
        $state['NoHmGc'] | Should -BeFalse -Because "only the named variable was set"
    }
}
