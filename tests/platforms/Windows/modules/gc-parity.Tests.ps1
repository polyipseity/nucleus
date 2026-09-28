<#
.SYNOPSIS
    Pester tests for nucleus-gc cross-host surface parity.

.DESCRIPTION
    scripts/gc.sh and scripts/gc.ps1 are the two halves of one user-visible
    command, so a capability present on one side and missing on the other is a
    defect on whichever host lacks it.  This suite reads the capability list out
    of gc.sh's own argument parser and asserts that every capability has a
    Windows counterpart, so the next gap surfaces as a failing test rather than
    as a discovery during a real garbage collection.

    Three groups are declared here rather than inferred, because each one is a
    deliberate design decision:

      * The six POSIX-only capabilities -- accepted and ignored.  Five of them
        because Windows has no nix store, no journald and no btrfs
        /nix/store; nix-artifacts-gc because the all action never calls
        Invoke-CleanupNix, so the switch has nothing to gate.  The set is
        cross-checked against gc.ps1's own help text, so a switch cannot
        quietly stop documenting itself as POSIX-only.

      * --vm-data-gc -- gc.ps1 spells its counterpart GCVMData, positively.
        A No-switch defaults to false, which on a "No" switch means "do not
        skip", so every weekly Windows run would collect VM data while POSIX
        did not.

      * The generation-retention values -- consumed only by
        src/scripts/services/nix-store-gc.sh on POSIX.  Their absence from
        gc.ps1 is correct, and this suite pins it so nobody closes the dry-run
        gap and then closes this one too.

    Neither script is executed.  A successful gc.ps1 invocation falls through
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

    # The param block text, taken from the parse tree so the assertion is about
    # what PowerShell binds rather than about how the line happens to be spaced.
    $Script:GcPs1Tokens = $null
    $Script:GcPs1ParseErrors = $null
    $Script:GcPs1Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $Script:GcPs1Path, [ref]$Script:GcPs1Tokens, [ref]$Script:GcPs1ParseErrors)
    $Script:GcPs1ParamText = $Script:GcPs1Ast.ParamBlock.Extent.Text

    # The capability list is the set of paired --x-gc|--no-x-gc case labels of
    # gc.sh's argument parser.  The -gc suffix is what separates a capability
    # flag from a value flag such as --log-max-size or --hm-expiry.
    $Script:GcShCapabilities = @(
        [regex]::Matches($Script:GcSh, '(?m)^  --(?:no-)?([a-z0-9-]+-gc)\)$') |
            ForEach-Object { $_.Groups[1].Value } |
            Sort-Object -Unique
    )

    # Capabilities with no No-switch on the Windows side, mapped to the switch
    # that implements them instead.  See .DESCRIPTION for why the sign differs.
    $Script:PositiveCounterparts = @{
        'vm-data-gc' = 'GCVMData'
    }

    # The POSIX-only set, spelled as gc.sh flag names so the comparison against
    # gc.sh is direct.  Each is verified against gc.ps1's help text below.
    # ref: allow-and-deny-lists.instructions.md#D6 -- these switches exist in
    # gc.ps1 only for CLI parity with gc.sh, and gc.ps1's own help text is the
    # cross-check, so the list must name exactly the switches that document
    # themselves POSIX-only. T2 (self-prune): a stale entry breaks the equality
    # against $Script:DocumentedIgnoredSwitches.
    $Script:PosixOnlyCapabilities = @(
        'duperemove-gc'
        'hm-gc'
        'journald-gc'
        'nix-artifacts-gc'
        'nix-gc'
        'system-gc'
    )

    # Generation retention is a nix-store concept.  src/scripts/services/nix-store-gc.sh
    # is the only consumer on POSIX; Windows has nowhere to keep generations.
    $Script:PosixOnlyValues = @(
        'generations-keep'
        'hm-generations-keep'
        'system-generations-keep'
    )

    # Every command in gc.ps1 that removes or rewrites state.  git is absent on
    # purpose: gc.ps1 shells out to it for both reads and removals, and only the
    # removals live inside the dry-run-aware helpers.
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
        'Invoke-LogExpiry'
        'Invoke-LogRotation'
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

    # The switches and values gc.ps1 itself promises to accept and ignore.  Read
    # from the comment-based help rather than from a second hand-written list, so
    # the two cannot drift apart unnoticed.
    $Script:DocumentedIgnored = @(
        [regex]::Matches($Script:GcPs1, '(?ms)^\.PARAMETER\s+(?<name>[A-Za-z]+)\r?\n(?<body>[^\r\n]*(?:\r?\n[ \t]+[^\r\n]*)*)') |
            Where-Object { $_.Groups['body'].Value -match 'POSIX-only' } |
            ForEach-Object { $_.Groups['name'].Value } |
            Sort-Object -Unique
    )
    $Script:DocumentedIgnoredSwitches = @($Script:DocumentedIgnored | Where-Object { $_ -like 'No*' })

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

    # The commands the destructive list matches, guarded or not.  Split out of
    # the guard walk so the total is assertable: a walk that matches nothing is
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
        # WHY: every assertion below iterates this list.  A regex that stopped
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

    It 'gives every gc.sh capability a Windows counterpart' {
        $missing = foreach ($capability in $Script:GcShCapabilities) {
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

    It 'documents exactly the POSIX-only capabilities as accepted and ignored' {
        $expected = @(
            foreach ($capability in $Script:PosixOnlyCapabilities) {
                'No' + (ConvertTo-PascalCapabilityName -Capability $capability)
            }
        ) | Sort-Object -Unique
        $expected | Should -Not -BeNullOrEmpty -Because 'the POSIX-only set must not be empty, or the test proves nothing'
        $Script:DocumentedIgnoredSwitches | Should -Be $expected
    }

    It 'documents the POSIX-only duration values as accepted and ignored' {
        # WHY: the nix-store durations are string parameters rather than skip
        # switches, so they are ignored by the same promise and belong to the
        # same set; dropping either half would make the parity claim partial.
        $Script:DocumentedIgnored | Should -Contain 'Expiry'
        $Script:DocumentedIgnored | Should -Contain 'HmExpiry'
        $Script:DocumentedIgnored | Should -Contain 'NixExpiry'
        $Script:DocumentedIgnored | Should -Not -Contain 'LogMaxSize'
    }

    It 'keeps the generation-retention values out of gc.ps1' {
        # WHY: they configure nix-store generations, which exist only on POSIX.
        # Adding them to gc.ps1 would be a parity fix in name only: no Windows
        # code would read them.
        foreach ($value in $Script:PosixOnlyValues) {
            $Script:GcSh | Should -Match ('--' + $value + '\b') -Because "gc.sh must still expose --$value"
        }
        foreach ($value in $Script:PosixOnlyValues) {
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
