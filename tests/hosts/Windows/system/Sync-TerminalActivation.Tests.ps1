# Sync-TerminalActivation.Tests.ps1
# Pester regression tests for the Sync-TerminalActivation module.

BeforeAll {
    # Dot-source the module to make its function available.
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\src\hosts\Windows\modules\system\Sync-TerminalActivation.ps1'
    . $modulePath
}

Describe 'Sync-TerminalActivation module loading' {
    It 'Should dot-source without errors' {
        # If we reach this test, BeforeAll succeeded.
        $true | Should -Be $true
    }

    It 'Should export the Sync-TerminalActivation function' {
        Get-Command -Name 'Sync-TerminalActivation' -ErrorAction Stop | Should -Not -BeNullOrEmpty
    }
}

Describe 'Sync-TerminalActivation behavior' {
    BeforeEach {
        # Use a temp directory as USERPROFILE so manifest paths are isolated.
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "nucleus-test-$([System.IO.Path]::GetRandomFileName())"
        # check-suppress:SuppressMessageAttribute: PSUseDeclaredVarsMoreThanAssignments — $null = intentional; New-Item returns DirectoryInfo, discarded in test setup
        $null = New-Item -Path $script:testRoot -ItemType Directory -Force
        $script:originalUserProfile = $env:USERPROFILE
        $env:USERPROFILE = $script:testRoot
    }

    AfterEach {
        $env:USERPROFILE = $script:originalUserProfile
        if ($script:testRoot -and (Test-Path -LiteralPath $script:testRoot)) {
            # check-suppress:suppression_doc: cleanup in test teardown — failure is acceptable
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Should be a no-op when no manifest exists' {
        { Sync-TerminalActivation } | Should -Not -Throw
    }

    It 'Should be a no-op and delete empty manifest' {
        $manifestDir = Join-Path -Path $script:testRoot -ChildPath '.config\nucleus'
        # check-suppress:SuppressMessageAttribute: PSUseDeclaredVarsMoreThanAssignments — $null = intentional; New-Item returns DirectoryInfo, discarded in test setup
        $null = New-Item -Path $manifestDir -ItemType Directory -Force
        $manifestPath = Join-Path -Path $manifestDir -ChildPath 'terminal-activations.list'
        # check-suppress:SuppressMessageAttribute: PSUseDeclaredVarsMoreThanAssignments — $null = intentional; New-Item returns FileInfo, discarded in test setup
        $null = New-Item -Path $manifestPath -ItemType File -Force

        Sync-TerminalActivation

        Test-Path -LiteralPath $manifestPath | Should -Be $false
    }

    It 'Should execute a single command from the manifest' {
        $manifestDir = Join-Path -Path $script:testRoot -ChildPath '.config\nucleus'
        # check-suppress:SuppressMessageAttribute: PSUseDeclaredVarsMoreThanAssignments — $null = intentional; New-Item returns DirectoryInfo, discarded in test setup
        $null = New-Item -Path $manifestDir -ItemType Directory -Force
        $manifestPath = Join-Path -Path $manifestDir -ChildPath 'terminal-activations.list'
        $markerPath = Join-Path -Path $script:testRoot -ChildPath 'marker-single'
        "New-Item -Path '$markerPath' -ItemType File -Force" | Out-File -LiteralPath $manifestPath -Encoding ASCII

        Sync-TerminalActivation

        Test-Path -LiteralPath $markerPath | Should -Be $true
        Test-Path -LiteralPath $manifestPath | Should -Be $false
    }

    It 'Should skip comment lines' {
        $manifestDir = Join-Path -Path $script:testRoot -ChildPath '.config\nucleus'
        # check-suppress:SuppressMessageAttribute: PSUseDeclaredVarsMoreThanAssignments — $null = intentional; New-Item returns DirectoryInfo, discarded in test setup
        $null = New-Item -Path $manifestDir -ItemType Directory -Force
        $manifestPath = Join-Path -Path $manifestDir -ChildPath 'terminal-activations.list'
        $markerPath = Join-Path -Path $script:testRoot -ChildPath 'marker-comment'
        @(
            '# macos-configure-safari-defaults'
            '# a comment line'
            "New-Item -Path '$markerPath' -ItemType File -Force"
        ) | Out-File -LiteralPath $manifestPath -Encoding ASCII

        Sync-TerminalActivation

        Test-Path -LiteralPath $markerPath | Should -Be $true
    }

    It 'Should continue on command failure' {
        $manifestDir = Join-Path -Path $script:testRoot -ChildPath '.config\nucleus'
        # check-suppress:SuppressMessageAttribute: PSUseDeclaredVarsMoreThanAssignments — $null = intentional; New-Item returns DirectoryInfo, discarded in test setup
        $null = New-Item -Path $manifestDir -ItemType Directory -Force
        $manifestPath = Join-Path -Path $manifestDir -ChildPath 'terminal-activations.list'
        $markerPath = Join-Path -Path $script:testRoot -ChildPath 'marker-after-fail'
        @(
            'throw "simulated failure"'
            "New-Item -Path '$markerPath' -ItemType File -Force"
        ) | Out-File -LiteralPath $manifestPath -Encoding ASCII

        # Should not throw — errors are non-fatal.
        { Sync-TerminalActivation } | Should -Not -Throw
        Test-Path -LiteralPath $markerPath | Should -Be $true
    }
}
