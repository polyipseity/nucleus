<#
.SYNOPSIS
    Guard that the Windows CamillaDSP statefile is named the same way everywhere
    it is named.
.DESCRIPTION
    Three files independently spell the camilladsp statefile, and nothing in the
    build couples them:

        src/platforms/Windows/modules/scripts/CamillaDSP-autoconfig.ps1
            is the supervisor wrapper the sync module copies into the user
            profile. Its param() block is what the scheduled task has to bind.
        src/platforms/Windows/modules/user/Sync-CamillaDSPService.ps1
            builds the scheduled-task argument string and the -StateFile value
            from Get-CamillaDSPStateDir.
        src/modules/configs/camillagui-backend/config-Windows.yml
            tells the GUI backend where the same statefile lives.

    A mismatch is neither a parse nor a build failure. The task either cannot
    bind -StateFile at logon, which leaves a registered task whose wrapper exits
    immediately, or the daemon and the GUI backend disagree about where state
    lives. Both stay silent until someone reads a log, which is why this drift
    has to be caught by a test rather than by a compiler.

    Sources are read through the PowerShell parser and the YAML reader rather
    than through regular expressions over raw text, so reformatting or renaming
    a local does not break the guard. No scheduled-task, registry, or COM API is
    touched, so the suite runs on macOS and Linux as well as Windows.

.NOTES
    Environment variables: (none)
    Exit codes: 0 on success; 1 on failure
#>

Describe 'Windows CamillaDSP statefile wiring' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..')).Path

        $script:wrapperPath = Join-Path -Path $script:repoRoot -ChildPath 'src/platforms/Windows/modules/scripts/CamillaDSP-autoconfig.ps1'
        $script:syncModulePath = Join-Path -Path $script:repoRoot -ChildPath 'src/platforms/Windows/modules/user/Sync-CamillaDSPService.ps1'
        $script:stateDirLibPath = Join-Path -Path $script:repoRoot -ChildPath 'src/scripts/services/camilladsp-deviceselect.ps1'
        $script:guiConfigPath = Join-Path -Path $script:repoRoot -ChildPath 'src/modules/configs/camillagui-backend/config-Windows.yml'

        # Parse a script so only its real parameters and commands are read, never
        # a comment or a string that merely looks like one.
        function Get-ScriptAst {
            param(
                [Parameter(Mandatory)]
                [string]$Path
            )

            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
            if ($errors) {
                throw "Get-ScriptAst: $Path does not parse: $($errors[0].Message)"
            }

            return $ast
        }

        # Value of one named parameter of a parsed command. A string literal or
        # an expandable string yields its text with any $var references kept
        # verbatim, which is what a parameter-name match needs; anything else
        # yields its source text so a caller can still see what was passed.
        function Get-CommandParameterValue {
            param(
                [Parameter(Mandatory)]
                [System.Management.Automation.Language.CommandAst]$Command,

                [Parameter(Mandatory)]
                [string]$Name
            )

            $elements = $Command.CommandElements
            for ($index = 0; $index -lt $elements.Count - 1; $index++) {
                $element = $elements[$index]
                if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and
                    $element.ParameterName -eq $Name) {
                    $value = $elements[$index + 1]
                    if ($value -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                        $value -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
                        return $value.Value
                    }

                    return $value.Extent.Text
                }
            }

            return $null
        }

        # Site 1: the supervisor's param() block, which is the whole set of
        # parameters the task action has to supply.
        $wrapperAst = Get-ScriptAst -Path $script:wrapperPath
        $script:wrapperParameters = @(
            $wrapperAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
        )

        # Site 2a: the single argument string the sync module hands the task.
        $syncAst = Get-ScriptAst -Path $script:syncModulePath
        $script:scheduledTaskActions = @($syncAst.FindAll(
            {
                $args[0] -is [System.Management.Automation.Language.CommandAst] -and
                $args[0].GetCommandName() -eq 'New-ScheduledTaskAction'
            },
            $true
        ))
        $script:taskArgument = if ($script:scheduledTaskActions.Count -eq 1) {
            Get-CommandParameterValue -Command $script:scheduledTaskActions[0] -Name 'Argument'
        }
        else {
            $null
        }

        # Site 2b: the -StateFile value, built as
        # Join-Path -Path (Get-CamillaDSPStateDir) -ChildPath '<leaf>'.
        $script:stateFileJoins = @(
            $syncAst.FindAll(
                {
                    $args[0] -is [System.Management.Automation.Language.CommandAst] -and
                    $args[0].GetCommandName() -eq 'Join-Path'
                },
                $true
            ) | Where-Object { (Get-CommandParameterValue -Command $_ -Name 'Path') -match 'Get-CamillaDSPStateDir' }
        )
        $script:stateFileLeaf = if ($script:stateFileJoins.Count -eq 1) {
            Get-CommandParameterValue -Command $script:stateFileJoins[0] -Name 'ChildPath'
        }
        else {
            $null
        }

        # Site 2c: the Windows directory that value is built under, read from the
        # helper the sync module dot-sources. Off Windows the helper returns an
        # XDG path and the Windows branch is unreachable at runtime, so the
        # branch is read from the source instead of executed.
        $stateDirLibAst = Get-ScriptAst -Path $script:stateDirLibPath
        $script:stateDirFunctions = @($stateDirLibAst.FindAll(
            {
                $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $args[0].Name -eq 'Get-CamillaDSPStateDir'
            },
            $true
        ))
        $script:windowsStateDirLeaf = $null
        if ($script:stateDirFunctions.Count -eq 1) {
            $windowsBranchJoins = @(
                foreach ($ifStatement in @($script:stateDirFunctions[0].Body.FindAll(
                    { $args[0] -is [System.Management.Automation.Language.IfStatementAst] },
                    $true
                ))) {
                    foreach ($clause in $ifStatement.Clauses) {
                        if ($clause.Item1.Extent.Text.Trim() -ne '$IsWindows') { continue }

                        $clause.Item2.FindAll(
                            {
                                $args[0] -is [System.Management.Automation.Language.CommandAst] -and
                                $args[0].GetCommandName() -eq 'Join-Path'
                            },
                            $true
                        )
                    }
                }
            )
            if ($windowsBranchJoins.Count -eq 1) {
                $script:windowsStateDirLeaf = Get-CommandParameterValue -Command $windowsBranchJoins[0] -Name 'ChildPath'
            }
        }

        # One separator and no trailing separator on either side, so a backslash
        # in PowerShell and a forward slash in YAML cannot read as a difference.
        $script:daemonStatefileTail = $null
        if ($null -ne $script:windowsStateDirLeaf -and $null -ne $script:stateFileLeaf) {
            $script:daemonStatefileTail = @(
                ($script:windowsStateDirLeaf -replace '\\', '/').TrimEnd('/')
                ($script:stateFileLeaf -replace '\\', '/').TrimEnd('/')
            ) -join '/'
        }

        # Site 3: the GUI backend's own answer.
        $script:guiConfig = ConvertFrom-Yaml -Yaml (Get-Content -Raw -LiteralPath $script:guiConfigPath)
        $script:guiStatefilePath = $script:guiConfig.statefile_path
    }

    It 'declares the supervisor parameters the task action has to bind' {
        $script:wrapperParameters.Count | Should -BeGreaterThan 0
        $script:wrapperParameters | Should -Contain 'StateFile'
    }

    It 'builds exactly one scheduled task action argument string' {
        $script:scheduledTaskActions.Count | Should -Be 1 -Because 'the wrapper parameters are bound by this one string'
        $script:taskArgument | Should -Not -BeNullOrEmpty
    }

    It 'passes every supervisor parameter from the task action' {
        $script:taskArgument | Should -Not -BeNullOrEmpty

        $missing = @(
            foreach ($parameterName in $script:wrapperParameters) {
                # Case-insensitive, as PowerShell binds parameters, and anchored
                # so a shorter name cannot satisfy a longer one.
                if ($script:taskArgument -notmatch ('(?i)(?<![\w-])-' + [regex]::Escape($parameterName) + '\b')) {
                    $parameterName
                }
            }
        )

        $missing | Should -BeNullOrEmpty -Because "every wrapper parameter must be bound by the task action, unbound: $($missing -join ', ')"
    }

    It 'passes the statefile as the value the sync module computes' {
        $script:stateFileJoins.Count | Should -Be 1 -Because 'the -StateFile value has to come from Get-CamillaDSPStateDir'
        $script:stateFileLeaf | Should -Be 'statefile.yml'
        $script:taskArgument | Should -Not -BeNullOrEmpty
        $script:taskArgument | Should -Match '(?i)-StateFile\s+"?\$stateFile\b'
    }

    It 'names the Windows state directory under nucleus/camilladsp' {
        $script:stateDirFunctions.Count | Should -Be 1
        $script:windowsStateDirLeaf | Should -Not -BeNullOrEmpty
        ($script:windowsStateDirLeaf -replace '\\', '/') | Should -Be 'nucleus/camilladsp'
    }

    It 'builds the daemon statefile under the shared state directory' {
        $script:daemonStatefileTail | Should -Be 'nucleus/camilladsp/statefile.yml'
    }

    It 'points the GUI backend at the daemon statefile' {
        $script:guiStatefilePath | Should -Not -BeNullOrEmpty -Because 'config-Windows.yml must declare statefile_path'

        $guiStatefilePathSlash = $script:guiStatefilePath -replace '\\', '/'
        $guiStatefilePathSlash.EndsWith('/' + $script:daemonStatefileTail) | Should -BeTrue -Because "statefile_path '$script:guiStatefilePath' must end with '$script:daemonStatefileTail'"
    }
}
