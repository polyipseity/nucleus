<#
.SYNOPSIS
    Pester coverage for the agents-overlay skills source resolution.
.DESCRIPTION
    Guards the defect that motivated the overlay change: the skills source used
    to be a hardcoded src\modules\configs\agents\skills path, which does not
    exist.  These tests assert the overlay resolver returns the fixture skills
    tree, that the stale path is gone from src/, that the disable path removes
    managed skill links while leaving foreign directories, and (on Windows) that
    the enabled path links every source entry.
.NOTES
    Environment variables: (none — $HOME is overridden at script scope)
    Exit codes: 0 on success; 1 on failure
    The enabled-path test runs on Windows only: the Developer-Mode guard is a
    Windows platform requirement.  icacls is shimmed off Windows.
#>

Describe 'Sync-AgentsSkillManifest overlay skills resolution' {
    BeforeAll {
        Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\Format-NucleusOutput.psm1') -Force
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\ConfigHelpers.ps1')
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\user\Sync-AgentsSkillManifest.ps1')

        # The delete-protection module shells out to icacls, which only exists on
        # Windows; the shim keeps the suite runnable on macOS/Linux.
        function icacls { $global:LASTEXITCODE = 0 }

        $script:repoRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-skillmanifest-" + [guid]::NewGuid().ToString('N'))
        $script:homeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-skillhome-" + [guid]::NewGuid().ToString('N'))
        $script:overlaySkillsDir = Join-Path $script:repoRoot 'src\users\default\agents\skills'
        $null = New-Item -ItemType Directory -Path (Join-Path $script:overlaySkillsDir 'alpha') -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $null = Set-Content -Path (Join-Path $script:overlaySkillsDir 'alpha\SKILL.md') -Value '# alpha' -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
        $null = New-Item -ItemType Directory -Path (Join-Path $script:homeRoot '.agents\skills') -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup

        $script:realRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\..')).Path
        $script:originalHome = $HOME
        Set-Variable -Name HOME -Value $script:homeRoot -Force
    }
    AfterAll {
        Set-Variable -Name HOME -Value $script:originalHome -Force
        foreach ($path in @($script:repoRoot, $script:homeRoot)) {
            if ($path -and (Test-Path -LiteralPath $path)) {
                # check-suppress:suppression_doc: cleanup in test teardown -- failure is acceptable
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'resolves the skills source through the per-user agents overlay' {
        $resolved = Resolve-UserConfigFirstLevelEntry -User 'test-user' -ConfigName 'agents' -EntryName 'skills' -RepoRoot $script:repoRoot
        $resolved | Should -Be $script:overlaySkillsDir
    }

    It 'no longer references the non-existent src/modules/configs/agents path' {
        # WHY: the scan covers the Windows module tree this change owns.  The
        # remaining references in src\hosts\Windows\apply.ps1 are comment text
        # updated by the caller's wiring pass, which this lane must not touch.
        $stalePattern = 'modules[\\/]configs[\\/]agents'
        $hits = @(
            Get-ChildItem -LiteralPath (Join-Path $script:realRepoRoot 'src\platforms\Windows') -Recurse -File -Include '*.ps1', '*.sh' |
                Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match $stalePattern }
        )
        $hits | Should -BeNullOrEmpty
    }

    It 'removes managed skill links and keeps foreign directories when disabled' {
        $skillsDir = Join-Path $script:homeRoot '.agents\skills'
        $managedLink = Join-Path $skillsDir 'alpha'
        if (Test-Path -LiteralPath $managedLink) { Remove-Item -LiteralPath $managedLink -Force }
        $null = New-Item -ItemType SymbolicLink -Path $managedLink -Target (Join-Path $script:overlaySkillsDir 'alpha')  # check-suppress:suppression_doc: New-Item returns FileInfo, discarded in test setup
        $foreignDir = Join-Path $skillsDir 'fetched-skill'
        if (Test-Path -LiteralPath $foreignDir) { Remove-Item -LiteralPath $foreignDir -Recurse -Force }
        $null = New-Item -ItemType Directory -Path $foreignDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup

        Sync-AgentsSkillManifest -RepoRoot $script:repoRoot -User 'test-user' -Enabled:$false

        (Test-Path -LiteralPath $managedLink) | Should -Be $false
        (Test-Path -LiteralPath $foreignDir) | Should -Be $true
    }

    It 'links every source entry and skips a missing extra source' -Skip:(-not $IsWindows) {
        Sync-AgentsSkillManifest -RepoRoot $script:repoRoot -User 'test-user' -Enabled:$true
        (Get-Item -LiteralPath (Join-Path $script:homeRoot '.agents\skills\alpha') -Force).Target |
            Should -Be (Join-Path $script:overlaySkillsDir 'alpha')

        $extraSource = Join-Path $script:repoRoot 'src\users\default\agents\pi-extensions'
        $null = New-Item -ItemType Directory -Path $extraSource -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $null = New-Item -ItemType Directory -Path (Join-Path $extraSource 'beta') -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        Sync-AgentsSkillManifest -RepoRoot $script:repoRoot -User 'test-user' -Enabled:$true -ExtraSkillsSource $extraSource
        (Get-Item -LiteralPath (Join-Path $script:homeRoot '.agents\skills\beta') -Force).Target |
            Should -Be (Join-Path $extraSource 'beta')

        $missingSource = Join-Path $script:repoRoot 'src\users\default\agents\missing'
        # A layered source that has not been provisioned yet is informational, not
        # fatal: the superpowers plugin checkout legitimately may not exist.
        Sync-AgentsSkillManifest -RepoRoot $script:repoRoot -User 'test-user' -Enabled:$true -ExtraSkillsSource $missingSource
        (Test-Path -LiteralPath (Join-Path $script:homeRoot '.agents\skills\missing')) | Should -Be $false
    }
}
