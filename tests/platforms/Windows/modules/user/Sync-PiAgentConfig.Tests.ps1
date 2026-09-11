<#
.SYNOPSIS
    Pester coverage for the pi agent config symlinks in Sync-PiAgentConfig.ps1.
.DESCRIPTION
    Unit-tests the %USERPROFILE%\.pi\agent links on temp paths: an enabled run
    links extensions\ and settings.json to the overlay-resolved sources, re-runs
    are idempotent, and a disabled run removes the managed links without
    disturbing unmanaged content.
.NOTES
    Environment variables: (none — $HOME is overridden at script scope)
    Exit codes: 0 on success; 1 on failure
    Symlink creation requires elevation or Developer Mode on Windows; not
    required on macOS/Linux where the tests also run.
#>

Describe 'Sync-PiAgentConfig pi agent links' {
    BeforeAll {
        Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\Format-NucleusOutput.psm1') -Force
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\ConfigHelpers.ps1')
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\user\Sync-PiAgentConfig.ps1')

        $script:repoRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-picfg-" + [guid]::NewGuid().ToString('N'))
        $extensionsSourceDir = Join-Path $script:repoRoot 'src\users\default\agents\pi-extensions'
        $null = New-Item -ItemType Directory -Path $extensionsSourceDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $null = Set-Content -Path (Join-Path $extensionsSourceDir 'agents-bridge.ts') -Value 'export {};' -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
        $null = Set-Content -Path (Join-Path $script:repoRoot 'src\users\default\agents\pi-settings.json') -Value '{}' -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup

        $script:homeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-pihome-" + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:homeRoot -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup

        $script:originalHome = $HOME
        Set-Variable -Name HOME -Value $script:homeRoot -Force

        Mock Test-PiSymlinkPrivilege { return $true }
        Mock Set-ManagedSymlinkDeleteProtection { }
        Mock Remove-ManagedSymlinkDeleteProtection { }
    }
    AfterAll {
        Set-Variable -Name HOME -Value $script:originalHome -Force
        if ($script:repoRoot -and (Test-Path -LiteralPath $script:repoRoot)) {
            # check-suppress:suppression_doc: cleanup in test teardown -- failure is acceptable
            Remove-Item -LiteralPath $script:repoRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($script:homeRoot -and (Test-Path -LiteralPath $script:homeRoot)) {
            # check-suppress:suppression_doc: cleanup in test teardown -- failure is acceptable
            Remove-Item -LiteralPath $script:homeRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'links extensions and settings.json to the overlay-resolved sources on an enabled run' {
        $piDir = Join-Path $script:homeRoot '.pi\agent'
        $extensionsLink = Join-Path $piDir 'extensions'
        $settingsLink = Join-Path $piDir 'settings.json'
        Test-Path -LiteralPath $extensionsLink | Should -Be $false

        Sync-PiAgentConfig -RepoRoot $script:repoRoot -User 'testuser' -Enabled:$true > $null

        $extensionsItem = Get-Item -LiteralPath $extensionsLink -Force
        $extensionsItem.LinkType | Should -Be 'SymbolicLink'
        $extensionsItem.Target | Should -Be (Join-Path $script:repoRoot 'src\users\default\agents\pi-extensions')

        $settingsItem = Get-Item -LiteralPath $settingsLink -Force
        $settingsItem.LinkType | Should -Be 'SymbolicLink'
        $settingsItem.Target | Should -Be (Join-Path $script:repoRoot 'src\users\default\agents\pi-settings.json')
    }

    It 'is idempotent — re-running leaves the links intact' {
        $piDir = Join-Path $script:homeRoot '.pi\agent'
        $settingsLink = Join-Path $piDir 'settings.json'

        Sync-PiAgentConfig -RepoRoot $script:repoRoot -User 'testuser' -Enabled:$true > $null

        $item = Get-Item -LiteralPath $settingsLink -Force
        $item.LinkType | Should -Be 'SymbolicLink'
        $item.Target | Should -Be (Join-Path $script:repoRoot 'src\users\default\agents\pi-settings.json')
    }

    It 'relinks a wrong-target symlink instead of leaving it drifted' {
        $piDir = Join-Path $script:homeRoot '.pi\agent'
        $settingsLink = Join-Path $piDir 'settings.json'
        $staleSource = Join-Path $script:repoRoot 'src\users\default\agents\pi-settings.json'
        Remove-Item -LiteralPath $settingsLink -Force
        $null = New-Item -ItemType SymbolicLink -Path $settingsLink -Target $staleSource > $null  # check-suppress:suppression_doc: New-Item returns a FileInfo, discarded in test setup

        Sync-PiAgentConfig -RepoRoot $script:repoRoot -User 'testuser' -Enabled:$true > $null

        $item = Get-Item -LiteralPath $settingsLink -Force
        $item.Target | Should -Be (Join-Path $script:repoRoot 'src\users\default\agents\pi-settings.json')
    }

    It 'removes the managed links and keeps unmanaged content on a disabled run' {
        $piDir = Join-Path $script:homeRoot '.pi\agent'
        $extensionsLink = Join-Path $piDir 'extensions'
        $settingsLink = Join-Path $piDir 'settings.json'
        $unmanagedPath = Join-Path $piDir 'trust.json'
        $null = Set-Content -Path $unmanagedPath -Value '{}' -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup

        Sync-PiAgentConfig -RepoRoot $script:repoRoot -User 'testuser' -Enabled:$false > $null

        Test-Path -LiteralPath $extensionsLink | Should -Be $false
        Test-Path -LiteralPath $settingsLink | Should -Be $false
        Test-Path -LiteralPath $unmanagedPath | Should -Be $true
    }
}
