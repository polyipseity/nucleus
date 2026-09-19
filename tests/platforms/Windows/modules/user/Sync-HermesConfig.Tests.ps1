<#
.SYNOPSIS
    Pester coverage for the harness-bridge plugin link in Sync-HermesConfig.ps1.

.DESCRIPTION
    Unit-tests the plugin deployment on temp paths.  The link has to land in the
    root the pinned CLI reads (HERMES_HOME, which resolves to
    %LOCALAPPDATA%\hermes on Windows), so the suite asserts the target built from
    that root: an enabled run links the overlay-resolved source, a second run is
    idempotent, a link pointing elsewhere is recreated, a real directory is
    refused without being deleted, and a disabled run removes the managed link.

    The hermes CLI is absent throughout, so the enable half stops at its
    documented warning; the CLI contract is probed separately against the real
    binary.

.NOTES
    Environment variables: $HOME and $LOCALAPPDATA are overridden at script scope
    Exit codes: 0 on success; 1 on failure
    Symlink creation requires elevation or Developer Mode on Windows; not
    required on macOS/Linux where the tests also run.
#>

Describe 'Sync-HermesConfig harness-bridge plugin link' {
    BeforeAll {
        Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\Format-NucleusOutput.psm1') -Force
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\ConfigHelpers.ps1')
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\user\Sync-HermesConfig.ps1')

        # Fixture tree: the per-user overlay falls back to src/users/default/.
        $script:repoRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-hermescfg-" + [guid]::NewGuid().ToString('N'))
        $pluginSourceDir = Join-Path $script:repoRoot 'src\users\default\hermes\plugins\harness-bridge'
        $null = New-Item -ItemType Directory -Path $pluginSourceDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $null = Set-Content -Path (Join-Path $pluginSourceDir 'plugin.yaml') -Value 'name: harness-bridge' -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
        $script:pluginSource = $pluginSourceDir

        $script:homeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-hermeshome-" + [guid]::NewGuid().ToString('N'))
        $script:localAppData = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-hermeslad-" + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:homeRoot -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $null = New-Item -ItemType Directory -Path $script:localAppData -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $script:pluginLink = Join-Path $script:localAppData 'hermes\plugins\harness-bridge'

        $script:originalHome = $HOME
        $script:originalLocalAppData = $env:LOCALAPPDATA
        $script:originalAppData = $env:APPDATA
        Set-Variable -Name HOME -Value $script:homeRoot -Force
        $env:LOCALAPPDATA = $script:localAppData
        # The startup-folder sweep joins $env:APPDATA, which is Windows-only.
        $script:appData = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-hermesappdata-" + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:appData -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $env:APPDATA = $script:appData

        # The symlink privilege probe, the User-scope environment writes, the
        # hermes CLI lookup, and the delete-protection helpers are all stubbed so
        # nothing touches the real machine.  Get-Command itself is left alone:
        # Pester resolves mocked commands through it.
        Mock Test-HermesSymlinkPrivilege { return $true }
        Mock Get-HermesUserEnvVar { return $null }
        Mock Write-HermesUserEnvVar { }
        Mock Set-ManagedSymlinkDeleteProtection { }
        Mock Remove-ManagedSymlinkDeleteProtection { }

        # hermes is not installed in this sandbox: the enable half warns and stops.
        Mock Get-HermesCliPath { return $null }
        Mock Get-HermesGatewayService { return $null }
        Mock Get-HermesGatewayTask { return $null }
    }

    AfterAll {
        Set-Variable -Name HOME -Value $script:originalHome -Force
        $env:LOCALAPPDATA = $script:originalLocalAppData
        $env:APPDATA = $script:originalAppData
        foreach ($path in @($script:repoRoot, $script:homeRoot, $script:localAppData, $script:appData)) {
            if ($path -and (Test-Path -LiteralPath $path)) {
                # check-suppress:suppression_doc: cleanup in test teardown -- failure is acceptable
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    BeforeEach {
        if (Test-Path -LiteralPath $script:pluginLink) {
            # check-suppress:suppression_doc: test reset -- failure is acceptable
            Remove-Item -LiteralPath $script:pluginLink -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'links the plugin into HERMES_HOME on an enabled run' {
        Test-Path -LiteralPath $script:pluginLink | Should -Be $false

        Sync-HermesConfig -Enabled:$true -User 'testuser' -RepoRoot $script:repoRoot > $null

        $item = Get-Item -LiteralPath $script:pluginLink -Force
        $item.LinkType | Should -Be 'SymbolicLink'
        $item.Target | Should -Be $script:pluginSource
    }

    It 'keeps the same link on a second run' {
        Sync-HermesConfig -Enabled:$true -User 'testuser' -RepoRoot $script:repoRoot > $null
        $first = (Get-Item -LiteralPath $script:pluginLink -Force).Target

        Sync-HermesConfig -Enabled:$true -User 'testuser' -RepoRoot $script:repoRoot > $null

        (Get-Item -LiteralPath $script:pluginLink -Force).Target | Should -Be $first
    }

    It 'recreates a link that points at the wrong source' {
        $wrongSource = Join-Path $script:repoRoot 'src\users\default\hermes\plugins'
        $pluginParent = Split-Path -Path $script:pluginLink -Parent
        $null = New-Item -ItemType Directory -Path $pluginParent -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        New-Item -ItemType SymbolicLink -Path $script:pluginLink -Target $wrongSource > $null

        Sync-HermesConfig -Enabled:$true -User 'testuser' -RepoRoot $script:repoRoot > $null

        (Get-Item -LiteralPath $script:pluginLink -Force).Target | Should -Be $script:pluginSource
    }

    It 'refuses to replace a real directory instead of deleting it' {
        $null = New-Item -ItemType Directory -Path $script:pluginLink -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup

        { Sync-HermesConfig -Enabled:$true -User 'testuser' -RepoRoot $script:repoRoot } | Should -Throw

        Test-Path -LiteralPath $script:pluginLink -PathType Container | Should -Be $true
        (Get-Item -LiteralPath $script:pluginLink -Force).LinkType | Should -BeNullOrEmpty
    }

    It 'warns and stops at the enable step when hermes is absent' {
        $warnings = @()
        Sync-HermesConfig -Enabled:$true -User 'testuser' -RepoRoot $script:repoRoot -WarningVariable warnings > $null

        ($warnings -join ' ') | Should -Match 'hermes binary not found'
        (Get-Item -LiteralPath $script:pluginLink -Force).LinkType | Should -Be 'SymbolicLink'
    }

    It 'removes the managed link when disabled' {
        Sync-HermesConfig -Enabled:$true -User 'testuser' -RepoRoot $script:repoRoot > $null
        Test-Path -LiteralPath $script:pluginLink | Should -Be $true

        Sync-HermesConfig -Enabled:$false -User 'testuser' -RepoRoot $script:repoRoot > $null

        Test-Path -LiteralPath $script:pluginLink | Should -Be $false
    }
}
