<#
.SYNOPSIS
    Pester coverage for Invoke-PowerShellModuleSetup PSGallery convergence.
.DESCRIPTION
    The module removes every discovered copy of a pinned module and reinstalls the
    pin at CurrentUser scope. Two copies used to be a real failure: the old code
    took only the first Get-Module -ListAvailable result, so on a runner image
    carrying Pester 5.9.0 beside 3.4.0 the second copy survived and Install-Module
    warned that it was unsupported. The suite drives the real module against a
    temp fixture repo root with Get-Module, Uninstall-Module, Install-Module and
    Remove-Item mocked, so no module is touched and no network call happens.
.NOTES
    Environment variables: (none)
    Exit codes: 0 on success; 1 on failure
#>

Describe 'Invoke-PowerShellModuleSetup PSGallery convergence' {
    BeforeAll {
        Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\Format-NucleusOutput.psm1') -Force
        # WHY PowerShellGet explicitly: Install-Module and Uninstall-Module live
        # in it, and Pester resolves a Mock against the commands it can see, so
        # without the import the suite fails with CommandNotFoundException rather
        # than reaching the behaviour under test. Importing never installs.
        Import-Module PowerShellGet -ErrorAction Stop

        $script:realRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\..')).Path
        $script:tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-psmodulesetup-" + [guid]::NewGuid().ToString('N'))

        # The module derives its repo root from its own location, so a copy inside
        # a synthetic tree is what lets the suite supply its own psgallery section.
        $script:fakeRoot = Join-Path $script:tempRoot 'fakeroot'
        $script:fakeSetupDir = Join-Path $script:fakeRoot 'src\platforms\Windows\modules\setup'
        $null = New-Item -ItemType Directory -Path $script:fakeSetupDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $null = New-Item -ItemType Directory -Path (Join-Path $script:fakeRoot 'src\lockfiles') -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup

        # The fixture carries one pin, so a case that asserts on a module name
        # cannot pass by accident through some other entry.
        $fixture = @{ psgallery = [ordered]@{ Pester = '6.2.0' } } | ConvertTo-Json -Depth 4

        # The module reads the per-user module path as the last PSModulePath entry,
        # so pointing that at a temp directory is what lets a case place a copy at
        # CurrentUser scope without writing to the real one. Restored in AfterAll,
        # because the Pester step runs every suite in one process.
        $script:currentUserRoot = Join-Path $script:tempRoot 'CurrentUserModules'
        $null = New-Item -ItemType Directory -Path $script:currentUserRoot -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $script:originalPsmPath = $env:PSModulePath
        $env:PSModulePath = (Join-Path $script:tempRoot 'MachineModules') + [IO.Path]::PathSeparator + $script:currentUserRoot
        $null = Set-Content -Path (Join-Path $script:fakeRoot 'src\lockfiles\lockfile.json') -Value $fixture  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
        Copy-Item -LiteralPath (Join-Path $script:realRepoRoot 'src\platforms\Windows\modules\setup\Invoke-PowerShellModuleSetup.ps1') -Destination (Join-Path $script:fakeSetupDir 'Invoke-PowerShellModuleSetup.ps1')
        . (Join-Path $script:fakeSetupDir 'Invoke-PowerShellModuleSetup.ps1')

        # Get-ModuleCopy — the shape Get-Module -ListAvailable yields: one entry
        # per version and per scope, each with the ModuleBase the sweep deletes.
        function Get-ModuleCopy {
            param(
                [Parameter(Mandatory)][string]$Version,
                [Parameter(Mandatory)][string]$Scope
            )

            return [PSCustomObject]@{
                Name        = 'Pester'
                Version     = [Version]$Version
                ModuleBase  = Join-Path $script:tempRoot (Join-Path $Scope (Join-Path 'Pester' $Version))
            }
        }

        # The mocked module directories have to exist on disk, because the sweep
        # checks each one and the removal is what the assertions observe.
        function Initialize-ModuleDirectory {
            param([Parameter(Mandatory)][string]$ModuleBase)

            $null = New-Item -ItemType Directory -Path $ModuleBase -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        }
    }

    AfterAll {
        $env:PSModulePath = $script:originalPsmPath
        if ($script:tempRoot -and (Test-Path -LiteralPath $script:tempRoot)) {
            # check-suppress:suppression_doc: cleanup in test teardown -- failure is acceptable
            Remove-Item -LiteralPath $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    BeforeEach {
        # Every case starts from the same single-copy state, so one case cannot
        # leave a copy behind for the next one to trip over.
        $script:copies = @()
        $script:removedDirectories = @()
        $script:installCalls = @()

        Mock Get-Module { return $script:copies }
        Mock Install-Module { $script:installCalls += $RequiredVersion }
        # Records instead of deleting, so a case can assert WHICH directories the
        # sweep reached. The delete itself is covered by the orphan case below,
        # which lets this through for one run.
        Mock Remove-Item {
            $script:removedDirectories += $Path
            # WHY the API call: the cmdlet is mocked, so a case asserting the
            # directory is gone would otherwise pass or fail on the mock rather
            # than on the sweep. Removing for real keeps the mock faithful to the
            # cmdlet it stands in for.
            [System.IO.Directory]::Delete($Path, $true)
        }
    }

    It 'removes every copy and installs the pin when two versions are present' {
        $newer = Get-ModuleCopy -Version '5.9.0' -Scope 'MachineModules'
        $stale = Get-ModuleCopy -Version '3.4.0' -Scope 'MachineModules'
        Initialize-ModuleDirectory -ModuleBase $newer.ModuleBase
        Initialize-ModuleDirectory -ModuleBase $stale.ModuleBase
        $script:copies = @($newer, $stale)

        Invoke-PowerShellModuleSetup

        # Both directories, not just the first. The old code removed one, so the
        # stale copy survived and the install below warned about it.
        $script:removedDirectories | Should -Contain $newer.ModuleBase
        $script:removedDirectories | Should -Contain $stale.ModuleBase
        @($script:removedDirectories).Count | Should -Be 2
        $script:installCalls | Should -Contain '6.2.0'
    }

    It 'removes the stale copy and keeps the converged pin when the pinned version is already present' {
        $pin = Get-ModuleCopy -Version '6.2.0' -Scope 'CurrentUserModules'
        $stale = Get-ModuleCopy -Version '3.4.0' -Scope 'MachineModules'
        Initialize-ModuleDirectory -ModuleBase $pin.ModuleBase
        Initialize-ModuleDirectory -ModuleBase $stale.ModuleBase
        $script:copies = @($pin, $stale)

        Invoke-PowerShellModuleSetup

        # The case the old early `continue` skipped: the pin was satisfied, so it
        # returned before removing anything and the stale copy stayed.
        $script:removedDirectories | Should -Contain $stale.ModuleBase
        @($script:removedDirectories).Count | Should -Be 1
        # The pin is already where this module installs, so taking it away would
        # buy a PSGallery round trip per run and no change.
        $script:removedDirectories | Should -Not -Contain $pin.ModuleBase
        @($script:installCalls) | Should -BeNullOrEmpty
    }

    It 'reinstalls the pin when only a machine-scope copy of that version is present' {
        $pinElsewhere = Get-ModuleCopy -Version '6.2.0' -Scope 'MachineModules'
        Initialize-ModuleDirectory -ModuleBase $pinElsewhere.ModuleBase
        $script:copies = @($pinElsewhere)

        Invoke-PowerShellModuleSetup

        # CurrentUser is the scope this module owns, so a pin sitting in the
        # machine scope is a copy it has to converge rather than accept.
        $script:removedDirectories | Should -Contain $pinElsewhere.ModuleBase
        $script:installCalls | Should -Contain '6.2.0'
    }

    It 'installs the pin when nothing is present' {
        $script:copies = @()

        Invoke-PowerShellModuleSetup

        $script:installCalls | Should -Be @('6.2.0')
        # Nothing was installed before this run, so there is nothing to sweep.
        @($script:removedDirectories) | Should -BeNullOrEmpty
    }

    It 'deletes the directory rather than only recording it' {
        # A recorded Remove-Item is not a removal. This is the guard on the mock
        # above: without a case that finds the directory gone, every other case
        # would pass whether or not the sweep touched the disk.
        $orphan = Get-ModuleCopy -Version '3.4.0' -Scope 'MachineModules'
        Initialize-ModuleDirectory -ModuleBase $orphan.ModuleBase
        $script:copies = @($orphan)

        Invoke-PowerShellModuleSetup

        $script:removedDirectories | Should -Contain $orphan.ModuleBase
        Test-Path -LiteralPath $orphan.ModuleBase | Should -BeFalse
    }
}
