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

    A fourth coupling lives in the heartbeat itself:
        src/scripts/services/camilladsp-heartbeat.ps1
            hashes the resolved playback and capture endpoints with the config.
    The fingerprint only covers the capture endpoint while every call that hashes
    or records a config passes -CaptureDevice, and a parameter added to one call
    site and not the other is silent: the daemon then stops re-pushing when the
    capture source changes. The parameter names and the call sites are read from
    the parsed source, so a rename or a reflow stays green while a missing
    argument does not.

    Sources are read through the PowerShell parser and the YAML reader rather
    than through regular expressions over raw text. Reformatting, renaming a
    local, spelling both Join-Path arguments positionally, and writing the
    Windows test as `$IsWindows -eq $true` all leave the guard green. It does
    pin the leaves it exists to protect (nucleus/camilladsp and statefile.yml)
    and it requires the action string to pass the Join-Path result itself to
    -StateFile, so a refactor that copies -Argument into a variable before
    New-ScheduledTaskAction is reported here until the suite is updated. No
    scheduled-task, registry, or COM API is touched, so the suite runs on macOS
    and Linux as well as Windows.

    The push boundary is guarded the same way: the capture endpoint the tick
    resolved is what a pushed playback device has to differ from, so the boundary
    must compare against its -CaptureDevice argument, refuse the three ways a
    push can feed the output back in, and never resolve the endpoint itself. A
    second resolution could observe a different system default than the one the
    tick used, which would make the comparison prove nothing. Those three
    refusals gate on a loopback capture, so the boundary is also driven rather
    than only read: its function definitions are sourced from the parsed file and
    called with the state directory, the resolver's answer, and the request log
    stubbed, which is the only way to see that a config that is not loopback
    reaches a request at all.

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

        # Text of one parsed argument. A string literal keeps its value and an
        # expandable string keeps its $var references verbatim, which is what a
        # caller matching on a variable name needs; anything else yields its
        # source text so the caller can still see what was passed.
        function Get-ArgumentText {
            param(
                [Parameter(Mandatory)]
                [System.Management.Automation.Language.Ast]$Argument
            )

            if ($Argument -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                $Argument -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
                return $Argument.Value
            }

            return $Argument.Extent.Text
        }

        # Value of one parameter of a parsed command, named or positional.
        # Element 0 is the command name, so -Position 1 is the first argument.
        # The positional form is the fallback because Join-Path binds the same
        # two parameters either way, and refactoring a call between the named
        # and the positional spelling is not a behavior change.
        function Get-CommandParameterValue {
            param(
                [Parameter(Mandatory)]
                [System.Management.Automation.Language.CommandAst]$Command,

                [Parameter(Mandatory)]
                [string]$Name,

                [int]$Position = 0
            )

            $elements = $Command.CommandElements
            for ($index = 0; $index -lt $elements.Count - 1; $index++) {
                $element = $elements[$index]
                if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and
                    $element.ParameterName -eq $Name) {
                    return Get-ArgumentText -Argument $elements[$index + 1]
                }
            }

            if ($Position -gt 0) {
                $positional = 0
                for ($index = 1; $index -lt $elements.Count; $index++) {
                    $element = $elements[$index]
                    # A named parameter consumes the element after it, so its
                    # value is never a positional argument.
                    if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                        $index++
                        continue
                    }

                    $positional++
                    if ($positional -eq $Position) {
                        return Get-ArgumentText -Argument $element
                    }
                }
            }

            return $null
        }

        # Name of the variable an expression is assigned to, with any scope or
        # drive qualifier dropped: the action string references $name, never
        # $script:name. Null when the expression is not an assignment target.
        function Get-AssignedVariableName {
            param(
                [Parameter(Mandatory)]
                [System.Management.Automation.Language.Ast]$Ast
            )

            $current = $Ast.Parent
            while ($null -ne $current -and $current -isnot [System.Management.Automation.Language.AssignmentStatementAst]) {
                $current = $current.Parent
            }

            if ($null -eq $current -or $current.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) {
                return $null
            }

            $variablePath = $current.Left.VariablePath.UserPath
            $qualifier = $variablePath.IndexOf(':')
            if ($qualifier -ge 0) {
                $variablePath = $variablePath.Substring($qualifier + 1)
            }

            return $variablePath
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
            ) | Where-Object { (Get-CommandParameterValue -Command $_ -Name 'Path' -Position 1) -match 'Get-CamillaDSPStateDir' }
        )
        $script:stateFileLeaf = if ($script:stateFileJoins.Count -eq 1) {
            Get-CommandParameterValue -Command $script:stateFileJoins[0] -Name 'ChildPath' -Position 2
        }
        else {
            $null
        }

        # Site 2b again: the variable that Join-Path result is assigned to. The
        # action has to pass this variable, whatever the source calls it, so the
        # guard below never pins a local name of its own.
        $script:stateFileVariable = if ($script:stateFileJoins.Count -eq 1) {
            Get-AssignedVariableName -Ast $script:stateFileJoins[0]
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
                        # Any positive test of $IsWindows selects the branch, so
                        # -eq $true or a spare set of parentheses still finds it;
                        # a negated or false-comparing test does not.
                        $condition = $clause.Item1.Extent.Text
                        if ($condition -notmatch '\$IsWindows\b') { continue }
                        if ($condition -match '(?i)(-not\s+|!)\s*\$IsWindows\b|\$IsWindows\s*-(eq\s*\$false|ne\s*\$true)\b|\$false\s*-eq\s*\$IsWindows\b') { continue }

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
                $script:windowsStateDirLeaf = Get-CommandParameterValue -Command $windowsBranchJoins[0] -Name 'ChildPath' -Position 2
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

        # Site 4: every heartbeat call that hashes or records a config, and the
        # parameters of the functions it calls, so a capture endpoint that reaches
        # one call site and not the other is reported.
        $script:heartbeatPath = Join-Path -Path $script:repoRoot -ChildPath 'src/scripts/services/camilladsp-heartbeat.ps1'
        $heartbeatAst = Get-ScriptAst -Path $script:heartbeatPath
        $fingerprintFunctionName = @(
            'Get-CamillaDSPConfigFingerprint'
            'Send-CamillaDSPConfig'
            'Test-CamillaDSPConfigChanged'
        )
        $script:fingerprintCalls = @($heartbeatAst.FindAll(
            {
                $args[0] -is [System.Management.Automation.Language.CommandAst] -and
                $fingerprintFunctionName -contains $args[0].GetCommandName()
            },
            $true
        ))
        $script:fingerprintCallsWithoutCapture = @(
            foreach ($call in $script:fingerprintCalls) {
                if (-not (Get-CommandParameterValue -Command $call -Name 'CaptureDevice')) {
                    $call.Extent.Text
                }
            }
        )
        $script:fingerprintFunctionParameters = @{}
        foreach ($definition in @($heartbeatAst.FindAll(
                    {
                        $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                        $fingerprintFunctionName -contains $args[0].Name
                    },
                    $true
                ))) {
            $script:fingerprintFunctionParameters[$definition.Name] = @(
                $definition.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
            )
        }

        # Site 4 again: the push boundary. Its guard conditions are read as
        # source text, and the capture resolver call is searched for inside Send
        # so a boundary that observes the endpoint a second time is reported.
        $script:sendDefinitions = @($heartbeatAst.FindAll(
            {
                $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $args[0].Name -eq 'Send-CamillaDSPConfig'
            },
            $true
        ))
        $script:sendGuardConditions = @()
        $script:sendCaptureResolutions = @()
        if ($script:sendDefinitions.Count -eq 1) {
            $script:sendGuardConditions = @(
                foreach ($guard in @($script:sendDefinitions[0].Body.FindAll(
                    { $args[0] -is [System.Management.Automation.Language.IfStatementAst] },
                    $true
                ))) {
                    foreach ($clause in $guard.Clauses) { $clause.Item1.Extent.Text }
                }
            )
            $script:sendCaptureResolutions = @($script:sendDefinitions[0].Body.FindAll(
                {
                    $args[0] -is [System.Management.Automation.Language.CommandAst] -and
                    $args[0].GetCommandName() -eq 'Get-CamillaDSPLoopbackCaptureDevice'
                },
                $true
            ))
        }

        # Site 4 again: the tick's single capture observation and the arguments
        # that carry it. A call outside a function body is a tick call, and every
        # one of those has to pass the variable the one resolution is assigned to.
        $script:captureResolutions = @($heartbeatAst.FindAll(
            {
                $args[0] -is [System.Management.Automation.Language.CommandAst] -and
                $args[0].GetCommandName() -eq 'Get-CamillaDSPLoopbackCaptureDevice'
            },
            $true
        ))
        $script:captureObservationVariable = if ($script:captureResolutions.Count -eq 1) {
            Get-AssignedVariableName -Ast $script:captureResolutions[0]
        }
        else {
            $null
        }
        $script:tickCaptureArgumentValues = @(
            @(
                foreach ($call in $script:fingerprintCalls) {
                    $current = $call.Parent
                    $insideFunction = $false
                    while ($null -ne $current) {
                        if ($current -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                            $insideFunction = $true
                            break
                        }
                        $current = $current.Parent
                    }
                    if (-not $insideFunction) {
                        Get-CommandParameterValue -Command $call -Name 'CaptureDevice'
                    }
                }
            ) | Select-Object -Unique
        )
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
        $script:stateFileVariable | Should -Not -BeNullOrEmpty -Because 'the Join-Path result has to be assigned to a variable the action can name'
        $script:taskArgument | Should -Not -BeNullOrEmpty

        # Anchored to the end of the token, because the guard names whichever
        # variable the source uses: a value with anything appended to it is a
        # different expression, not this variable.
        $stateFilePattern = '(?i)-StateFile\s+"?\$' + [regex]::Escape($script:stateFileVariable) + '(?=["''\s]|$)'
        $script:taskArgument | Should -Match $stateFilePattern
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

    It 'declares the capture endpoint on the heartbeat functions that hash a config' {
        $script:fingerprintFunctionParameters.Keys.Count | Should -Be 3
        foreach ($name in @('Get-CamillaDSPConfigFingerprint', 'Send-CamillaDSPConfig', 'Test-CamillaDSPConfigChanged')) {
            $script:fingerprintFunctionParameters[$name] | Should -Contain 'CaptureDevice' -Because "$name has to accept the capture endpoint the fingerprint covers"
        }
    }

    It 'passes the capture endpoint to every heartbeat call that hashes a config' {
        $script:fingerprintCalls.Count | Should -BeGreaterThan 0
        $script:fingerprintCallsWithoutCapture | Should -BeNullOrEmpty -Because "a call without -CaptureDevice stops the re-push when the capture source changes: $($script:fingerprintCallsWithoutCapture -join '; ')"
    }

    It 'refuses a push that would feed the output back in' {
        $script:sendDefinitions.Count | Should -Be 1

        $loopbackGuards = @($script:sendGuardConditions | Where-Object { $_ -match 'capture\.loopback' })
        $loopbackGuards.Count | Should -BeGreaterThan 0 -Because 'a capture that is not loopback has a capture-side device, so playback cannot equal it'

        $unknownGuards = @($script:sendGuardConditions | Where-Object { $_ -match '(?i)IsNullOrEmpty\(\$CaptureDevice\)' })
        $unknownGuards.Count | Should -BeGreaterThan 0 -Because 'an unresolved capture endpoint cannot be proven different from the device about to be pushed'

        $equalityGuards = @($script:sendGuardConditions | Where-Object { $_ -match '(?i)\$pushedDevice\s+-eq\s+\$CaptureDevice' })
        $equalityGuards.Count | Should -BeGreaterThan 0 -Because 'a playback device equal to the capture endpoint makes CamillaDSP capture its own output'
    }

    It 'compares the capture endpoint the tick resolved instead of resolving it again' {
        $script:sendCaptureResolutions.Count | Should -Be 0 -Because 'resolving the endpoint inside the push boundary could observe a different default than the tick did'
        $script:captureResolutions.Count | Should -Be 1 -Because 'the tick has to resolve the endpoint once and pass that value to every comparison'
        $script:captureObservationVariable | Should -Not -BeNullOrEmpty -Because 'the single resolution has to be assigned to a variable the calls can pass'

        $expected = '$' + $script:captureObservationVariable
        $script:tickCaptureArgumentValues.Count | Should -Be 1 -Because "every capture-taking call in the tick has to pass one observation, got: $($script:tickCaptureArgumentValues -join ', ')"
        $script:tickCaptureArgumentValues[0] | Should -Be $expected
    }
}

Describe 'Windows CamillaDSP push gate' {
    BeforeAll {
        $script:deviceSelectPath = Join-Path -Path $PSScriptRoot -ChildPath '../../../../src/scripts/services/camilladsp-deviceselect.ps1'
        $script:heartbeatPath = Join-Path -Path $PSScriptRoot -ChildPath '../../../../src/scripts/services/camilladsp-heartbeat.ps1'

        # The push boundary is driven rather than only read, because the fix is
        # about which configs reach a request. Only the function definitions are
        # sourced: the heartbeat's tick loop lives at top level, so dot-sourcing
        # the file would never return.
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:heartbeatPath, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors) {
            throw "camilladsp-heartbeat.ps1 does not parse: $($parseErrors[0].Message)"
        }

        $definitions = @($ast.FindAll(
            { $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] },
            $true
        ))
        . ([scriptblock]::Create(($definitions | ForEach-Object { $_.Extent.Text }) -join "`n"))

        # The state helpers the boundary records through, so the record is real
        # and lands in the temporary state directory the tests mock.
        . $script:deviceSelectPath
    }

    BeforeEach {
        $script:requests = @()
        $script:refusals = @()
        $script:stateDir = Join-Path -Path $TestDrive -ChildPath 'camilladsp-state'
        New-Item -ItemType Directory -Path $script:stateDir -Force > $null

        # The three things outside the boundary: the state directory, the
        # resolver's answer, and the request log. Everything else runs shipped.
        Mock Get-CamillaDSPStateDir { $script:stateDir }
        # An empty -TargetDevice is what the tick passes when the resolver found
        # no device, so the mock returns the config unchanged, as the resolver
        # does in that case.
        Mock Resolve-CamillaDSPPlaybackDevice { Get-Content -Raw -LiteralPath $ConfigPath }
        Mock Invoke-CamillaDSPRequest {
            $script:requests += $Payload
            return @{ SetConfig = @{ result = 'Ok' } }
        }
        Mock Write-CamillaDSPPushRefusalWarning {
            $script:refusals += [pscustomobject]@{ Cause = $Cause; Message = $Message }
        }
    }

    It 'pushes a null-device config when capture is not loopback' {
        $configPath = Join-Path -Path $TestDrive -ChildPath 'nonloopback.yml'
        Set-Content -LiteralPath $configPath -Value @'
devices:
  capture:
    type: Wasapi
    device: "Some Microphone"
    loopback: false
  playback:
    type: Wasapi
    device: null
'@

        Send-CamillaDSPConfig -ConfigPath $configPath -TargetDevice '' -CaptureDevice 'Some Microphone' -EndpointPort 1 | Should -BeTrue

        $script:requests.Count | Should -Be 1 -Because 'a capture that is not loopback cannot be the output a null playback device binds, so the config has to reach CamillaDSP'
        $pushedConfig = ($script:requests[0] | ConvertFrom-Json).SetConfig | ConvertFrom-Yaml
        $pushedConfig.devices.playback.device | Should -BeNullOrEmpty -Because 'the config keeps its null device so CamillaDSP binds its own default output'
        @($script:refusals | Where-Object { $_.Cause -eq 'unknown-capture' }).Count | Should -Be 0
    }

    It 'refuses a null-device loopback config that would bind the capture endpoint' {
        $configPath = Join-Path -Path $TestDrive -ChildPath 'loopback-null.yml'
        Set-Content -LiteralPath $configPath -Value @'
devices:
  capture:
    type: Wasapi
    device: null
    loopback: true
  playback:
    type: Wasapi
    device: null
'@

        Send-CamillaDSPConfig -ConfigPath $configPath -TargetDevice '' -CaptureDevice 'Some Speakers' -EndpointPort 1 | Should -BeFalse

        $script:requests.Count | Should -Be 0 -Because 'a null playback device on a loopback config binds the system default output, which is the endpoint the loopback capture reads'
        # The refusal keeps the resolver's own warning, so it records no cause here.
        $script:refusals.Count | Should -Be 0
    }

    It 'refuses a loopback config whose capture endpoint is unresolved' {
        $configPath = Join-Path -Path $TestDrive -ChildPath 'loopback-unresolved.yml'
        Set-Content -LiteralPath $configPath -Value @'
devices:
  capture:
    type: Wasapi
    device: null
    loopback: true
  playback:
    type: Wasapi
    device: "Some Speakers"
'@

        Send-CamillaDSPConfig -ConfigPath $configPath -TargetDevice '' -CaptureDevice '' -EndpointPort 1 | Should -BeFalse

        $script:requests.Count | Should -Be 0 -Because 'an unresolved loopback capture endpoint cannot be proven different from the device about to be pushed'
        @($script:refusals | Where-Object { $_.Cause -eq 'unknown-capture' }).Count | Should -Be 1
    }
}
