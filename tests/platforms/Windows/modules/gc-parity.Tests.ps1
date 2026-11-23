<#
.SYNOPSIS
    Pester tests for nucleus-gc cross-host surface parity.

.DESCRIPTION
    scripts/gc.sh and scripts/gc.ps1 are the two halves of one user-visible
    command, so a capability present on one side and missing on the other is a
    defect on whichever host lacks it. This suite reads the capability list out
    of gc.sh's own argument parser and asserts that every cross-platform
    capability has a Windows counterpart. POSIX-only capabilities are tagged
    platforms=["posix"] in the CLI spec and must be absent from gc.ps1.

    The POSIX-only set is derived from nucleus-cli-spec.json so the test follows
    the spec. Generation-retention values are POSIX-only nix-store concepts with
    no Windows counterpart; their absence from gc.ps1 is pinned here.

    Neither script is executed. A successful gc.ps1 invocation falls through
    into real garbage collection, and gc.sh needs bash plus the POSIX tree, so
    every assertion here reads file text or the parse tree instead.

    Run with: pwsh -NoProfile -Command "Invoke-Pester -Path tests/platforms/Windows/modules/gc-parity.Tests.ps1 -Output Detailed"
#>

BeforeAll {
    $Script:RepoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..')).Path
    $Script:GcShPath = Join-Path -Path $Script:RepoRoot -ChildPath 'scripts\gc.sh'
    $Script:GcPs1Path = Join-Path -Path $Script:RepoRoot -ChildPath 'scripts\gc.ps1'
    $Script:GcSh = Get-Content -LiteralPath $Script:GcShPath -Raw
    $Script:GcPs1 = Get-Content -LiteralPath $Script:GcPs1Path -Raw

    # The modules tree gc.ps1 dot-sources from: the same default the script
    # applies when -ModuleDir is not passed.
    $Script:ModuleDir = Join-Path -Path (Join-Path -Path $Script:RepoRoot -ChildPath 'src') -ChildPath 'platforms\Windows\modules'

    # The param block text, taken from the parse tree so the assertion is about
    # what PowerShell binds rather than about how the line happens to be spaced.
    $Script:GcPs1Tokens = $null
    $Script:GcPs1ParseErrors = $null
    $Script:GcPs1Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $Script:GcPs1Path, [ref]$Script:GcPs1Tokens, [ref]$Script:GcPs1ParseErrors)
    $Script:GcPs1ParamText = $Script:GcPs1Ast.ParamBlock.Extent.Text

    # The capability list is the set of paired --x-gc|--no-x-gc case labels of
    # gc.sh's argument parser. The -gc suffix is what separates a capability
    # flag from a value flag such as --log-max-size or --hm-expiry.
    $Script:GcShCapabilities = @(
        [regex]::Matches($Script:GcSh, '(?m)^  --(?:no-)?([a-z0-9-]+-gc)\)$') |
            ForEach-Object { $_.Groups[1].Value } |
            Sort-Object -Unique
    )

    # Capabilities with no No-switch on the Windows side, mapped to the switch
    # that implements them instead.
    $Script:PositiveCounterparts = @{
        'vm-data-gc' = 'GCVMData'
    }

    # POSIX-only gc capabilities are declared in the CLI spec. They must not be
    # accepted on Windows.
    $specPath = Join-Path -Path $Script:RepoRoot -ChildPath 'src\modules\completions\nucleus-cli-spec.json'
    $spec = Get-Content -LiteralPath $specPath -Raw | ConvertFrom-Json
    $gcApp = @($spec.apps | Where-Object { $_.name -eq 'gc' })[0]
    $Script:PosixOnlyGcCapabilities = @(
        $gcApp.globalFlags |
            Where-Object {
                $platforms = @($_.platforms)
                ($platforms -contains 'posix') -and (-not ($platforms -contains 'windows')) -and ($_.long -match '-gc$')
            } |
            ForEach-Object { ([string]$_.long) -replace '^--(?:no-)?', '' } |
            Sort-Object -Unique
    )

    # Generation retention and POSIX-only duration values configure nix-store GC
    # on POSIX only. Windows has no counterpart.
    $Script:PosixOnlyValueFlags = @(
        'hm-expiry'
        'nix-expiry'
        'generations-keep'
        'hm-generations-keep'
        'system-generations-keep'
    )

    # Every command in gc.ps1 that removes or rewrites state. git is absent on
    # purpose: gc.ps1 shells out to it for both reads and removals, and only the
    # removals live inside the dry-run-aware helpers.
    # Invoke-NucleusLogCommand is absent for a third reason: the logs action forwards
    # -DryRun into the child process as an argument, which the walk cannot see, so
    # listing it fails the guard walk on that call; its four step-7 calls are
    # guarded by an if the walk does see.
    # ref: allow-and-deny-lists.instructions.md#D5 -- a command missing from
    # this list is silently skipped by the guard walk, so a renamed helper would
    # disarm the dry-run coverage check instead of failing it. T2 (self-prune):
    # stale entries error in the destructive-list staleness test.
    $Script:DestructiveCommands = @(
        'Clear-DirectoryContentsIfPresent'
        'Clear-GitCache'
        'Clear-SccacheCache'
        'Invoke-AISync'
        'Invoke-CleanupNix'
        'Remove-Item'
        'Remove-StaleWallpaper'
        'Remove-VMGcItem'
        'Start-ScheduledTask'
        'bash'
        'scoop'
    )

    function ConvertTo-PascalCapabilityName {
        param([Parameter(Mandatory)][string]$Capability)
        return (($Capability -split '-') | ForEach-Object { $_.Substring(0, 1).ToUpper() + $_.Substring(1) }) -join ''
    }

    $Script:DeclaredParamNames = @(
        [regex]::Matches($Script:GcPs1ParamText, '\[(?:switch|string)\]\$(?<name>\w+)') |
            ForEach-Object { $_.Groups['name'].Value }
    )

    # A function counts as dry-run aware when it either tests $DryRun itself or
    # reports through Write-NucleusDryRun, which is how Invoke-CleanupNix opts
    # into ShouldProcess via -WhatIf rather than via a switch.
    $Script:DryRunAwareFunctions = @(
        $Script:GcPs1Ast.FindAll(
            { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
            $true) |
            Where-Object {
                $body = $_.Body.Extent.Text
                $body -match 'Write-NucleusDryRun' -or $body -match '\$DryRun'
            } |
            ForEach-Object { $_.Name }
    )

    # The commands the destructive list matches, guarded or not. Split out of
    # the guard walk so the total is assertable: a walk that matched nothing is
    # indistinguishable from a script in which nothing is unguarded.
    function Get-DestructiveCallNodeList {
        $commandNodes = $Script:GcPs1Ast.FindAll(
            { param($node) $node -is [System.Management.Automation.Language.CommandAst] },
            $true)

        return @(
            foreach ($node in $commandNodes) {
                $name = $node.GetCommandName()
                # The cargo-cache invocation is a call operator on a member
                # expression (& $cargoCacheCmd.Source), so it has no command
                # name and is matched by the shape of its first element instead.
                $isCargoCacheCall = $node.CommandElements.Count -gt 0 -and
                    $node.CommandElements[0].Extent.Text -match '\$\w+\.Source$'
                if (($Script:DestructiveCommands -contains $name) -or $isCargoCacheCall) {
                    $node
                }
            }
        )
    }

    function Get-UnguardedDestructiveCallSite {
        $dryRunAware = @{}
        foreach ($name in $Script:DryRunAwareFunctions) { $dryRunAware[$name] = $true }

        $sites = foreach ($node in (Get-DestructiveCallNodeList)) {
            $name = $node.GetCommandName()
            $guarded = $false
            # A call into a helper that guards itself is guarded by
            # construction, so the call's own name counts as an ancestor.
            if ($null -ne $name -and $dryRunAware.ContainsKey($name)) {
                $guarded = $true
            }
            $ancestor = $node
            while ($null -ne $ancestor) {
                # WHY: IfStatementAst exposes its tests through Clauses, not
                # through a Condition property, and an elseif guard puts the
                # $DryRun test on a later clause, so every clause is checked.
                if ($ancestor -is [System.Management.Automation.Language.IfStatementAst] -and
                    @($ancestor.Clauses | Where-Object { $_.Item1.Extent.Text -match '\$DryRun' }).Count -gt 0) {
                    $guarded = $true
                    break
                }
                if ($ancestor -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $dryRunAware.ContainsKey($ancestor.Name)) {
                    $guarded = $true
                    break
                }
                $ancestor = $ancestor.Parent
            }

            if (-not $guarded) {
                'scripts/gc.ps1 (line {0}): {1}' -f $node.Extent.StartLineNumber, $node.Extent.Text
            }
        }
        return @($sites)
    }
}

Describe 'gc.sh capability discovery' {
    It 'reads a non-empty capability list out of gc.sh' {
        # WHY: every assertion below iterates this list. A regex that stopped
        # matching would leave them vacuously true, so the list is proved
        # non-empty and proved to contain a known flag first.
        $Script:GcShCapabilities.Count | Should -BeGreaterThan 10
        $Script:GcShCapabilities | Should -Contain 'tool-cache-gc'
        $Script:GcShCapabilities | Should -Contain 'wallpaper-gc'
    }
}

Describe 'nucleus-gc surface parity' {
    It 'exposes a dry-run on both surfaces' {
        $Script:GcSh | Should -Match '--dry-run'
        $Script:GcPs1ParamText | Should -Match '\[switch\]\$DryRun'
    }

    It 'gives every cross-platform gc.sh capability a Windows counterpart' {
        $missing = foreach ($capability in $Script:GcShCapabilities) {
            if ($Script:PosixOnlyGcCapabilities -contains $capability) { continue }
            if ($Script:PositiveCounterparts.ContainsKey($capability)) {
                $switch = $Script:PositiveCounterparts[$capability]
            } else {
                $switch = 'No' + (ConvertTo-PascalCapabilityName -Capability $capability)
            }
            if ($Script:GcPs1ParamText -notmatch ('\[switch\]\$' + $switch + '\b')) {
                $capability + ' (expected [switch]$' + $switch + ')'
            }
        }
        $missing | Should -BeNullOrEmpty
    }

    It 'does not accept POSIX-only gc capabilities on Windows' {
        $Script:PosixOnlyGcCapabilities | Should -Not -BeNullOrEmpty -Because 'spec must declare POSIX-only gc capabilities or this test proves nothing'
        $present = foreach ($capability in $Script:PosixOnlyGcCapabilities) {
            $names = @('No' + (ConvertTo-PascalCapabilityName -Capability $capability))
            $names += (ConvertTo-PascalCapabilityName -Capability $capability)
            foreach ($name in $names) {
                if ($Script:DeclaredParamNames -contains $name) { $name }
            }
        }
        $present | Should -BeNullOrEmpty -Because 'POSIX-only gc capabilities must be rejected on Windows, not accepted and ignored'
    }

    It 'does not accept POSIX-only gc duration and generation-retention values on Windows' {
        $present = foreach ($value in $Script:PosixOnlyValueFlags) {
            $pascal = ConvertTo-PascalCapabilityName -Capability $value
            if ($Script:DeclaredParamNames -contains $pascal) { $pascal }
        }
        $present | Should -BeNullOrEmpty -Because 'POSIX-only gc values have no Windows counterpart and must not be bound as params'
        $Script:DeclaredParamNames | Should -Contain 'Expiry' -Because 'gc logs --expiry is cross-platform and the param must remain for logs forwarding'
        $Script:GcPs1 | Should -Match 'Resolve-NucleusArgument\b[^\r\n]*-BoundParameters\s+\$PSBoundParameters' -Because 'gc.ps1 must forward bound parameters so the shared normalizer can reject platform-restricted native bindings'
        $Script:GcPs1 | Should -Not -Match '\$IsWindows\s*-and\s*\$Expiry' -Because 'gc-root --expiry platform rejection must use the general normalizer mechanism, not a command-specific guard'
        $Script:GcPs1 | Should -Not -Match 'accepted but ignored on Windows \(POSIX-only\)' -Because 'accepted-and-ignored POSIX-only debt is removed'
    }

    It 'keeps the generation-retention values out of gc.ps1' {
        # WHY: they configure nix-store generations, which exist only on POSIX.
        # Adding them to gc.ps1 would be a parity fix in name only: no Windows
        # code would read them.
        foreach ($value in @('generations-keep', 'hm-generations-keep', 'system-generations-keep')) {
            $Script:GcSh | Should -Match ('--' + $value + '\b') -Because "gc.sh must still expose --$value"
            $pascal = ConvertTo-PascalCapabilityName -Capability $value
            $Script:DeclaredParamNames | Should -Not -Contain $pascal -Because "$value is POSIX-only and has no Windows counterpart"
            $Script:DeclaredParamNames | Should -Not -Contain ('No' + $pascal) -Because "$value is POSIX-only and needs no skip switch"
        }
    }
}

Describe 'nucleus-gc dry-run coverage' {
    It 'guards every destructive call site with $DryRun' {
        # WHY: without this, -DryRun could bind and bind true while the script
        # still collected for real, which is the exact failure that made gc.ps1
        # unusable as a preview.
        $destructiveCalls = @(Get-DestructiveCallNodeList)
        $destructiveCalls.Count | Should -BeGreaterThan 0 -Because (
            'a walk that matched nothing would be indistinguishable from a script in which nothing is unguarded')
        Get-UnguardedDestructiveCallSite | Should -BeNullOrEmpty
    }

    It 'has no stale entry in the destructive-command list' {
        # WHY: an entry the walk no longer matches means the command it named
        # has been renamed or removed, and the coverage check has quietly
        # stopped covering it. Nothing else in the suite would notice.
        $matched = @(Get-DestructiveCallNodeList | ForEach-Object { $_.GetCommandName() })
        foreach ($command in $Script:DestructiveCommands) {
            $matched | Should -Contain $command -Because (
                "$command is listed as destructive but the walk no longer matches it, so it is no longer covered (T2)")
        }
    }

    It 'reports a dry run through the existing Write-NucleusDryRun helper' {
        $Script:GcPs1 | Should -Match 'Write-NucleusDryRun'
        $Script:DryRunAwareFunctions | Should -Contain 'Clear-DirectoryContentsIfPresent'
        $Script:DryRunAwareFunctions | Should -Contain 'Clear-GitCache'
        $Script:DryRunAwareFunctions | Should -Contain 'Remove-VMGcItem'
    }

    It 'forwards -DryRun to Invoke-CleanupNix on the cleanup-nix action' {
        # WHY: Invoke-CleanupNix guards itself through ShouldProcess rather
        # than through an if ($DryRun) at the call site, so the walk above
        # counts its call as guarded by the callee's NAME and never reads the
        # argument list. The name is dry-run aware whether or not -DryRun is
        # forwarded, so only the argument list proves that `gc.ps1 cleanup-nix
        # -DryRun` previews instead of deleting real result symlinks.
        $calls = @(
            $Script:GcPs1Ast.FindAll(
                { param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-CleanupNix' },
                $true)
        )
        $calls | Should -Not -BeNullOrEmpty -Because 'the -Action cleanup-nix branch must still reach Invoke-CleanupNix'

        foreach ($call in $calls) {
            $call.Extent.Text | Should -Match '-WhatIf:\$DryRun' -Because (
                'gc.ps1 line {0} calls Invoke-CleanupNix and must pass -WhatIf:$DryRun' -f $call.Extent.StartLineNumber)
        }
    }
}

Describe 'nucleus-gc module imports' {
    It 'dot-sources every module from the directory that holds it' {
        # WHY: the dot-sources are the only wiring between gc.ps1 and the modules
        # tree, and nothing else here or in the analyzers notices when a module
        # moves: the import line keeps naming the old directory, the function it
        # defined never appears, and gc.ps1 aborts under its own
        # $ErrorActionPreference = 'Stop' before it reaches any action.
        # Both spellings the script could use are read: Join-Path with the
        # parameter names dropped, and a plain interpolation. A pattern anchored
        # on the -Path/-ChildPath spelling skipped a rewritten line while the
        # other imports kept the case green, which is the leak it exists to close.
        $imports = @(
            [regex]::Matches($Script:GcPs1, 'Join-Path\b[^\r\n"]*\$resolvedModuleDir[^\r\n"]*"(?<child>[^"]+)"') |
                ForEach-Object { $_.Groups['child'].Value }
            [regex]::Matches($Script:GcPs1, '"\$resolvedModuleDir(?<child>[^"]+)"') |
                ForEach-Object { $_.Groups['child'].Value }
        )
        $imports.Count | Should -BeGreaterThan 0 -Because (
            'an extractor that matched nothing would pass this case no matter which module moved')

        $unresolved = @(
            foreach ($child in $imports) {
                $segments = @($child -split '[\\/]' | Where-Object { $_ })
                $leaf = $segments[-1]
                $candidate = Join-Path -Path $Script:ModuleDir -ChildPath ($segments -join '\')
                if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                    "$child (not found under $Script:ModuleDir)"
                }
                # WHY the directory listing rather than the item's .Name: on a
                # case-insensitive filesystem Get-Item echoes the requested case,
                # so its .Name cannot tell a case-only regression from a correct
                # import. The listing carries the stored names.
                elseif (@(Get-ChildItem -LiteralPath (Split-Path -Parent $candidate) -Force -File |
                        Where-Object { $_.Name -ceq $leaf }).Count -eq 0) {
                    "$child (only a differently cased name exists under $(Split-Path -Parent $candidate))"
                }
            }
        )
        $unresolved | Should -BeNullOrEmpty
    }
}
