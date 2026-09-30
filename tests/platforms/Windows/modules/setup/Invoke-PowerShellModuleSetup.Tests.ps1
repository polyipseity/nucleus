<#
.SYNOPSIS
    Pester coverage for Invoke-PowerShellModuleSetup PSGallery convergence.
.DESCRIPTION
    The module removes every discovered copy of a pinned module that is at or
    above the pin and reinstalls the pin at CurrentUser scope. Two copies used to
    be a real failure: the old code took only the first Get-Module -ListAvailable
    result, so the second copy survived and Install-Module warned that it was
    unsupported. A copy below the pin is left alone, because PowerShell loads the
    highest version available and such a copy is inert. A copy that cannot be
    removed is recorded against that copy and thrown once at the end, so the
    remaining copies are still swept and the pin is still installed. The suite
    drives the real module against a temp fixture repo root with Get-Module,
    Uninstall-Module, Install-Module, Remove-Item, Enable-ModuleTreeRemoval and
    Clear-ModuleTreeReadOnlyAttribute mocked, so no module is touched, no
    ownership or attribute change runs, and no network call happens.
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
        $script:grantedPaths = @()
        $script:clearedReadOnlyPaths = @()
        $script:removedModules = @()
        $script:installCalls = @()
        $script:undeletablePaths = @()
        # WHY the one shared ordered log: the read-only clearing and the delete
        # are separate mocked calls, and a case cannot prove which came first
        # from two unordered lists.
        $script:operationLog = @()

        Mock Get-Module { return $script:copies }
        # WHY mocked: the real helper would take ownership of whatever path it is
        # given. The CI bootstrap step exercises it for real; here it only has to
        # record that the sweep asked for it, and where.
        Mock Enable-ModuleTreeRemoval { $script:grantedPaths += $Path; $script:operationLog += "grant:$Path" }
        # WHY mocked for the same reason: the real helper shells out to attrib,
        # and a case only needs to know that the sweep asked for it, and where.
        Mock Clear-ModuleTreeReadOnlyAttribute { $script:clearedReadOnlyPaths += $Path; $script:operationLog += "clear-readonly:$Path" }
        Mock Remove-Module { $script:removedModules += $Name }
        Mock Install-Module { $script:installCalls += $RequiredVersion }
        # Records instead of deleting, so a case can assert WHICH directories the
        # sweep reached. The delete itself is covered by the orphan case below,
        # which lets this through for one run.
        Mock Remove-Item {
            $script:operationLog += "remove:$Path"
            $script:removedDirectories += $Path
            # WHY the API call: the cmdlet is mocked, so a case asserting the
            # directory is gone would otherwise pass or fail on the mock rather
            # than on the sweep. Removing for real keeps the mock faithful to the
            # cmdlet it stands in for.
            [System.IO.Directory]::Delete($Path, $true)
        }
    }

    It 'removes every copy above the pin and installs the pin when two versions are present' {
        $newer = Get-ModuleCopy -Version '7.0.0' -Scope 'MachineModules'
        $older = Get-ModuleCopy -Version '6.5.0' -Scope 'MachineModules'
        Initialize-ModuleDirectory -ModuleBase $newer.ModuleBase
        Initialize-ModuleDirectory -ModuleBase $older.ModuleBase
        $script:copies = @($newer, $older)

        Invoke-PowerShellModuleSetup

        # Both directories, not just the first. The old code removed one, so the
        # second copy survived and the install below warned about it.
        $script:removedDirectories | Should -Contain $newer.ModuleBase
        $script:removedDirectories | Should -Contain $older.ModuleBase
        @($script:removedDirectories).Count | Should -Be 2
        $script:installCalls | Should -Contain '6.2.0'
    }

    It 'leaves a copy below the pin on disk while still sweeping one above it' {
        $higher = Get-ModuleCopy -Version '7.0.0' -Scope 'MachineModules'
        $lower = Get-ModuleCopy -Version '3.4.0' -Scope 'MachineModules'
        Initialize-ModuleDirectory -ModuleBase $higher.ModuleBase
        Initialize-ModuleDirectory -ModuleBase $lower.ModuleBase
        $script:copies = @($higher, $lower)

        Invoke-PowerShellModuleSetup

        # The version floor: PowerShell loads the highest version available, so a
        # copy under the pin cannot shadow it and stays where the image put it.
        # This is the Pester 3.4.0 the runner image ships beside a 6.2.0 pin, and
        # deleting it is what turned that runner red.
        @($script:removedDirectories) | Should -Not -Contain $lower.ModuleBase
        Test-Path -LiteralPath $lower.ModuleBase | Should -BeTrue
        # A copy this module does not sweep is a copy it must not take ownership
        # of either.
        @($script:grantedPaths) | Should -Not -Contain $lower.ModuleBase
        # The floor spares only what is below the pin: the copy above it still goes.
        $script:removedDirectories | Should -Contain $higher.ModuleBase
        @($script:removedDirectories).Count | Should -Be 1
        $script:installCalls | Should -Contain '6.2.0'
    }

    It 'removes the copy above the pin and keeps the converged pin when the pinned version is already present' {
        $pin = Get-ModuleCopy -Version '6.2.0' -Scope 'CurrentUserModules'
        $higher = Get-ModuleCopy -Version '6.5.0' -Scope 'MachineModules'
        Initialize-ModuleDirectory -ModuleBase $pin.ModuleBase
        Initialize-ModuleDirectory -ModuleBase $higher.ModuleBase
        $script:copies = @($pin, $higher)

        Invoke-PowerShellModuleSetup

        # The case the old early `continue` skipped: the pin was satisfied, so it
        # returned before removing anything and the shadowing copy stayed.
        $script:removedDirectories | Should -Contain $higher.ModuleBase
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

    It 'grants delete access before removing a copy outside the per-user path' {
        $imageCopy = Get-ModuleCopy -Version '6.2.0' -Scope 'MachineModules'
        Initialize-ModuleDirectory -ModuleBase $imageCopy.ModuleBase
        $script:copies = @($imageCopy)

        Invoke-PowerShellModuleSetup

        # A machine-scope copy at the pin version is a target, because PowerShell
        # breaks a version tie by path order. Such a copy under Program Files can
        # be TrustedInstaller-owned, and a plain Remove-Item on it is denied even
        # elevated.
        $script:grantedPaths | Should -Contain $imageCopy.ModuleBase
        $script:removedDirectories | Should -Contain $imageCopy.ModuleBase
    }

    It 'leaves the per-user pin alone and grants it nothing' {
        $pin = Get-ModuleCopy -Version '6.2.0' -Scope 'CurrentUserModules'
        Initialize-ModuleDirectory -ModuleBase $pin.ModuleBase
        $script:copies = @($pin)

        Invoke-PowerShellModuleSetup

        # Taking ownership of a tree this repository installed itself would be a
        # permission change with nothing behind it.
        @($script:grantedPaths) | Should -BeNullOrEmpty
        @($script:removedDirectories) | Should -BeNullOrEmpty
        @($script:installCalls) | Should -BeNullOrEmpty
    }

    It 'unloads a loaded copy before deleting it' {
        $imageCopy = Get-ModuleCopy -Version '6.5.0' -Scope 'MachineModules'
        Initialize-ModuleDirectory -ModuleBase $imageCopy.ModuleBase
        $script:copies = @($imageCopy)

        Invoke-PowerShellModuleSetup

        # WHY the assertion is weaker than it looks: the Get-Module mock answers
        # every call, so it reports a loaded module whenever any copy is listed.
        # In production the unload is attempted for a loaded copy and skipped for
        # an unloaded one, and either way the removal is what the next assertion
        # actually proves.
        $script:removedModules | Should -Contain 'Pester'
        $script:removedDirectories | Should -Contain $imageCopy.ModuleBase
    }

    It 'deletes the directory rather than only recording it' {
        # A recorded Remove-Item is not a removal. This is the guard on the mock
        # above: without a case that finds the directory gone, every other case
        # would pass whether or not the sweep touched the disk.
        $orphan = Get-ModuleCopy -Version '6.5.0' -Scope 'MachineModules'
        Initialize-ModuleDirectory -ModuleBase $orphan.ModuleBase
        $script:copies = @($orphan)

        Invoke-PowerShellModuleSetup

        $script:removedDirectories | Should -Contain $orphan.ModuleBase
        Test-Path -LiteralPath $orphan.ModuleBase | Should -BeFalse
    }

    It 'keeps sweeping the other copies when one copy cannot be removed' {
        $stubborn = Get-ModuleCopy -Version '6.5.0' -Scope 'MachineModules'
        $newer = Get-ModuleCopy -Version '7.0.0' -Scope 'MachineModules'
        $older = Get-ModuleCopy -Version '6.3.0' -Scope 'MachineModules'
        foreach ($copy in @($stubborn, $newer, $older)) {
            Initialize-ModuleDirectory -ModuleBase $copy.ModuleBase
        }
        $script:copies = @($newer, $stubborn, $older)
        # The runner image shape: one copy is denied, and the copies behind it in
        # the listing still have to go. The old code stopped at the first failure.
        # WHY script scope and not a closure variable: a mock body is evaluated
        # outside the It scope, so the path has to reach it through $script.
        $script:undeletablePaths = @($stubborn.ModuleBase)
        Mock Remove-Item {
            throw "Access to the path '$Path\Pester.bat' is denied."
        } -ParameterFilter { $script:undeletablePaths -contains $Path }

        { Invoke-PowerShellModuleSetup } | Should -Throw

        $script:removedDirectories | Should -Not -Contain $stubborn.ModuleBase
        Test-Path -LiteralPath $stubborn.ModuleBase | Should -BeTrue
        $script:removedDirectories | Should -Contain $newer.ModuleBase
        $script:removedDirectories | Should -Contain $older.ModuleBase
        Test-Path -LiteralPath $newer.ModuleBase | Should -BeFalse
    }

    It 'still installs the pin when a copy could not be removed' {
        $stubborn = Get-ModuleCopy -Version '6.5.0' -Scope 'MachineModules'
        Initialize-ModuleDirectory -ModuleBase $stubborn.ModuleBase
        $script:copies = @($stubborn)
        $script:undeletablePaths = @($stubborn.ModuleBase)
        Mock Remove-Item {
            throw "Access to the path '$Path' is denied."
        } -ParameterFilter { $script:undeletablePaths -contains $Path }

        { Invoke-PowerShellModuleSetup } | Should -Throw

        # The pin is the point of the module, so one undeletable image copy must
        # not cost the host its pin as well. The failure is still raised, after
        # the install rather than instead of it.
        $script:installCalls | Should -Contain '6.2.0'
    }

    It 'reports every copy that could not be removed in one failure' {
        $first = Get-ModuleCopy -Version '6.5.0' -Scope 'MachineModules'
        $second = Get-ModuleCopy -Version '7.0.0' -Scope 'MachineModules'
        $removable = Get-ModuleCopy -Version '6.3.0' -Scope 'MachineModules'
        foreach ($copy in @($first, $second, $removable)) {
            Initialize-ModuleDirectory -ModuleBase $copy.ModuleBase
        }
        $script:copies = @($first, $second, $removable)
        $script:undeletablePaths = @($first.ModuleBase, $second.ModuleBase)
        Mock Remove-Item {
            throw "Access to the path '$Path' is denied."
        } -ParameterFilter { $script:undeletablePaths -contains $Path }

        $failure = { Invoke-PowerShellModuleSetup } | Should -Throw -PassThru

        # Every failed copy is named with its version and its path, so the one
        # throw is the whole report rather than the first copy the loop hit.
        $failure.Exception.Message | Should -BeLike '*Pester 6.5.0 at *'
        $failure.Exception.Message | Should -BeLike '*Pester 7.0.0 at *'
        $failure.Exception.Message | Should -BeLike "*$($first.ModuleBase)*"
        $failure.Exception.Message | Should -BeLike "*$($second.ModuleBase)*"
        # The copy that could be removed still was.
        $script:removedDirectories | Should -Contain $removable.ModuleBase
    }

    It 'clears the read-only attribute before the delete and only outside the per-user path' {
        $imageCopy = Get-ModuleCopy -Version '6.5.0' -Scope 'MachineModules'
        $userCopy = Get-ModuleCopy -Version '7.0.0' -Scope 'CurrentUserModules'
        Initialize-ModuleDirectory -ModuleBase $imageCopy.ModuleBase
        Initialize-ModuleDirectory -ModuleBase $userCopy.ModuleBase
        $script:copies = @($imageCopy, $userCopy)

        Invoke-PowerShellModuleSetup

        # A read-only file inside an image tree is denied exactly the way a
        # permission problem is, so the attribute has to be cleared before the
        # delete rather than diagnosed after it failed.
        $clearIndex = [array]::IndexOf($script:operationLog, "clear-readonly:$($imageCopy.ModuleBase)")
        $removeIndex = [array]::IndexOf($script:operationLog, "remove:$($imageCopy.ModuleBase)")
        $clearIndex | Should -BeGreaterThan -1
        $removeIndex | Should -BeGreaterThan -1
        $clearIndex | Should -BeLessThan $removeIndex
        $script:clearedReadOnlyPaths | Should -Contain $imageCopy.ModuleBase
        # The per-user copy is ours, so its attributes are not rewritten even
        # though it is above the pin and therefore a sweep target.
        @($script:clearedReadOnlyPaths) | Should -Not -Contain $userCopy.ModuleBase
        @($script:grantedPaths) | Should -Not -Contain $userCopy.ModuleBase
        $script:removedDirectories | Should -Contain $userCopy.ModuleBase
    }
}
