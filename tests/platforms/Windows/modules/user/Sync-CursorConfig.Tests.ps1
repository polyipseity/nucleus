<#
.SYNOPSIS
    Pester coverage for the Cursor IDE settings symlink (Class C) in Sync-CursorConfig.ps1.
.DESCRIPTION
    Unit-tests the IDE settings.json symlink under %APPDATA%\Cursor\User on
    temp paths: enabled runs link settings.json into the IDE User dir (and
    keep it out of ~/.cursor/), re-runs are idempotent, a wrong-target symlink
    is relinked, and disabled runs remove the managed link.
.NOTES
    Environment variables: (none — $HOME is overridden at script scope)
    Exit codes: 0 on success; 1 on failure
    Symlink creation requires elevation or Developer Mode on Windows; not
    required on macOS/Linux where the tests also run.
#>

Describe 'Sync-CursorConfig IDE settings symlink (Class C)' {
    BeforeAll {
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\ConfigHelpers.ps1')
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\user\Sync-CursorConfig.ps1')
        $script:repoRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-cursorcfg-" + [guid]::NewGuid().ToString('N'))
        $defaultCursorDir = Join-Path $script:repoRoot 'src\users\default\cursor'
        $null = New-Item -ItemType Directory -Path $defaultCursorDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $null = Set-Content -Path (Join-Path $defaultCursorDir 'settings.json') -Value '{}' -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
        $null = Set-Content -Path (Join-Path $defaultCursorDir 'mcp.json') -Value '{}' -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup

        $script:homeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-cursorhome-" + [guid]::NewGuid().ToString('N'))
        $agentsDir = Join-Path $script:homeRoot '.agents'
        $null = New-Item -ItemType Directory -Path $agentsDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup

        $script:originalHome = $HOME
        Set-Variable -Name HOME -Value $script:homeRoot -Force

        Mock Test-DeveloperModeOrAdmin { return $true }
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

    It 'links settings.json into the IDE User dir on an enabled run' {
        $ideSettingsLink = Join-Path $script:homeRoot 'AppData\Roaming\Cursor\User\settings.json'
        Test-Path -LiteralPath $ideSettingsLink | Should -Be $false

        Sync-CursorConfig -RepoRoot $script:repoRoot -Enabled:$true -Username 'testuser' > $null

        $item = Get-Item -LiteralPath $ideSettingsLink -Force
        $item.LinkType | Should -Be 'SymbolicLink'
        $expectedSource = Join-Path $script:repoRoot 'src\users\default\cursor\settings.json'
        $item.Target | Should -Be $expectedSource
        # settings.json is skip-named: it must NOT be converged into ~/.cursor/
        Test-Path -LiteralPath (Join-Path $script:homeRoot '.cursor\settings.json') | Should -Be $false
        # other overlay entries still converge into ~/.cursor/
        $mcpLink = Join-Path $script:homeRoot '.cursor\mcp.json'
        Test-Path -LiteralPath $mcpLink | Should -Be $true
        $mcpItem = Get-Item -LiteralPath $mcpLink -Force
        $mcpItem.LinkType | Should -Be 'SymbolicLink'
    }

    It 'is idempotent — re-running leaves the link intact' {
        $ideSettingsLink = Join-Path $script:homeRoot 'AppData\Roaming\Cursor\User\settings.json'
        Test-Path -LiteralPath $ideSettingsLink | Should -Be $true

        { Sync-CursorConfig -RepoRoot $script:repoRoot -Enabled:$true -Username 'testuser' > $null } | Should -Not -Throw

        $item = Get-Item -LiteralPath $ideSettingsLink -Force
        $item.LinkType | Should -Be 'SymbolicLink'
        $expectedSource = Join-Path $script:repoRoot 'src\users\default\cursor\settings.json'
        $item.Target | Should -Be $expectedSource
    }

    It 'relinks a wrong-target symlink to the overlay source' {
        $ideSettingsLink = Join-Path $script:homeRoot 'AppData\Roaming\Cursor\User\settings.json'
        $wrongTarget = Join-Path $script:homeRoot 'wrong-target.json'
        $null = Set-Content -Path $wrongTarget -Value '{}' -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
        $null = Remove-Item -LiteralPath $ideSettingsLink -Force  # check-suppress:suppression_doc: Remove-Item returns nothing useful, discarded in test setup
        $null = New-Item -ItemType SymbolicLink -Path $ideSettingsLink -Target $wrongTarget -Force  # check-suppress:suppression_doc: New-Item returns FileInfo, discarded in test setup

        Sync-CursorConfig -RepoRoot $script:repoRoot -Enabled:$true -Username 'testuser' > $null

        $item = Get-Item -LiteralPath $ideSettingsLink -Force
        $item.LinkType | Should -Be 'SymbolicLink'
        $expectedSource = Join-Path $script:repoRoot 'src\users\default\cursor\settings.json'
        $item.Target | Should -Be $expectedSource
    }

    It 'removes the IDE settings link on a disabled run' {
        $ideSettingsLink = Join-Path $script:homeRoot 'AppData\Roaming\Cursor\User\settings.json'
        Test-Path -LiteralPath $ideSettingsLink | Should -Be $true

        Sync-CursorConfig -RepoRoot $script:repoRoot -Enabled:$false -Username 'testuser' > $null

        Test-Path -LiteralPath $ideSettingsLink | Should -Be $false
    }
}
