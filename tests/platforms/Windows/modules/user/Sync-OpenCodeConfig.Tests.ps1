<#
.SYNOPSIS
    Pester coverage for the opencode config and agent-bridge symlinks.
.DESCRIPTION
    Drives Sync-OpenCodeConfig against a fixture repo overlay and a temp HOME:
    enabled deploys the three links with overlay-resolved sources, re-runs are
    idempotent, a missing bridge target or missing overlay config is a hard
    error, disabled removes only managed links, and a foreign file is preserved.
.NOTES
    Environment variables: (none — $HOME is overridden at script scope)
    Exit codes: 0 on success; 1 on failure
    Symlink creation requires elevation or Developer Mode on Windows; not
    required on macOS/Linux where the tests also run.  icacls is shimmed off
    Windows.
#>

Describe 'Sync-OpenCodeConfig opencode config and bridges' {
    BeforeAll {
        Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\Format-NucleusOutput.psm1') -Force
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\ConfigHelpers.ps1')
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\user\Sync-OpenCodeConfig.ps1')

        # The delete-protection module shells out to icacls, which only exists on
        # Windows; the shim keeps the suite runnable on macOS/Linux.
        function icacls { $global:LASTEXITCODE = 0 }

        $script:tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-opencode-" + [guid]::NewGuid().ToString('N'))
        $script:repoRoot = Join-Path $script:tempRoot 'repo'
        $script:homeRoot = Join-Path $script:tempRoot 'home'
        $script:agentsConfigDir = Join-Path $script:repoRoot 'src\users\default\opencode'
        $null = New-Item -ItemType Directory -Path $script:agentsConfigDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $null = New-Item -ItemType Directory -Path (Join-Path $script:homeRoot '.agents\agents') -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $null = New-Item -ItemType Directory -Path (Join-Path $script:homeRoot '.agents\prompts') -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $null = Set-Content -Path (Join-Path $script:agentsConfigDir 'opencode.jsonc') -Value '{"$schema":"https://opencode.ai/config.json"}' -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup

        $script:openCodeDir = Join-Path $script:homeRoot '.config\opencode'
        $script:configLink = Join-Path $script:openCodeDir 'opencode.jsonc'
        $script:agentsLink = Join-Path $script:openCodeDir 'agents'
        $script:commandsLink = Join-Path $script:openCodeDir 'commands'
        $script:configTarget = Join-Path $script:agentsConfigDir 'opencode.jsonc'
        $script:agentsTarget = Join-Path $script:homeRoot '.agents\agents'
        $script:commandsTarget = Join-Path $script:homeRoot '.agents\prompts'

        $script:originalHome = $HOME
        Set-Variable -Name HOME -Value $script:homeRoot -Force
    }
    AfterAll {
        Set-Variable -Name HOME -Value $script:originalHome -Force
        if ($script:tempRoot -and (Test-Path -LiteralPath $script:tempRoot)) {
            # check-suppress:suppression_doc: cleanup in test teardown -- failure is acceptable
            Remove-Item -LiteralPath $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'links the config and the two agent bridges into the overlay and shared tree' {
        Sync-OpenCodeConfig -RepoRoot $script:repoRoot -User 'test-user' -Enabled:$true

        (Get-Item -LiteralPath $script:configLink -Force).Target | Should -Be $script:configTarget
        (Get-Item -LiteralPath $script:agentsLink -Force).Target | Should -Be $script:agentsTarget
        (Get-Item -LiteralPath $script:commandsLink -Force).Target | Should -Be $script:commandsTarget
    }

    It 'is idempotent across repeated runs' {
        Sync-OpenCodeConfig -RepoRoot $script:repoRoot -User 'test-user' -Enabled:$true
        { Sync-OpenCodeConfig -RepoRoot $script:repoRoot -User 'test-user' -Enabled:$true } | Should -Not -Throw

        (Get-Item -LiteralPath $script:configLink -Force).Target | Should -Be $script:configTarget
        (Get-Item -LiteralPath $script:commandsLink -Force).Target | Should -Be $script:commandsTarget
    }

    It 'fails hard when a bridge target is missing' {
        Remove-Item -LiteralPath $script:commandsTarget -Recurse -Force

        { Sync-OpenCodeConfig -RepoRoot $script:repoRoot -User 'test-user' -Enabled:$true } | Should -Throw

        $null = New-Item -ItemType Directory -Path $script:commandsTarget -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
    }

    It 'fails hard when the overlay config is missing' {
        $overlayConfig = Join-Path $script:agentsConfigDir 'opencode.jsonc'
        Remove-Item -LiteralPath $overlayConfig -Force

        { Sync-OpenCodeConfig -RepoRoot $script:repoRoot -User 'test-user' -Enabled:$true } | Should -Throw

        $null = Set-Content -Path $overlayConfig -Value '{}' -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
    }

    It 'refuses to overwrite a foreign file at a link path' {
        if (Test-Path -LiteralPath $script:configLink) { Remove-Item -LiteralPath $script:configLink -Force }
        $null = Set-Content -Path $script:configLink -Value '{"user":"data"}' -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup

        { Sync-OpenCodeConfig -RepoRoot $script:repoRoot -User 'test-user' -Enabled:$true } | Should -Throw
        (Get-Content -LiteralPath $script:configLink -Raw) | Should -Be '{"user":"data"}'

        Remove-Item -LiteralPath $script:configLink -Force
    }

    It 'removes only the managed links when disabled' {
        Sync-OpenCodeConfig -RepoRoot $script:repoRoot -User 'test-user' -Enabled:$true

        Sync-OpenCodeConfig -RepoRoot $script:repoRoot -User 'test-user' -Enabled:$false

        (Test-Path -LiteralPath $script:configLink) | Should -Be $false
        (Test-Path -LiteralPath $script:agentsLink) | Should -Be $false
        (Test-Path -LiteralPath $script:commandsLink) | Should -Be $false
        (Test-Path -LiteralPath $script:agentsTarget) | Should -Be $true
    }
}
