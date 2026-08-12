<#
.SYNOPSIS
    Verifies Get-VMGuestSshPublicKey resolves keys from the shared manifest.
.DESCRIPTION
    Runtime tests with a temporary USERPROFILE/.ssh fixture. Paths come from
    src/modules/vm-guest-ssh-public-key-paths.json.
.NOTES
    Run with: pwsh -NoProfile -Command "Invoke-Pester tests/hosts/Windows/system/vm-guest-ssh-public-key.Tests.ps1 -Passthru"
    Exit codes: 0 on success; 1 on failure
#>

BeforeAll {
    $ErrorActionPreference = 'Stop'

    $RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\..\')
    $GetVMGuestSshPublicKeyPath = Join-Path $RepoRoot 'src\platforms\Windows\modules\system\Get-VMGuestSshPublicKey.ps1'
    . $GetVMGuestSshPublicKeyPath

    $FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) "nucleus-vm-guest-ssh-$([Guid]::NewGuid().ToString())"
    $FixtureSshDir = Join-Path $FixtureRoot '.ssh'
    New-Item -ItemType Directory -Path $FixtureSshDir -Force > $null

    $script:OriginalUserProfile = $env:USERPROFILE
    $env:USERPROFILE = $FixtureRoot

    $StaticKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyForTests nucleus-vm-guest-ssh-test'
    $PersonalKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPersonalKeyForTests nucleus-personal'

    Set-Content -Path (Join-Path $FixtureSshDir 'id_ed25519.pub') -Value $StaticKey -NoNewline
    Set-Content -Path (Join-Path $FixtureSshDir 'ssh_personal_testuser.pub') -Value $PersonalKey -NoNewline
}

AfterAll {
    $env:USERPROFILE = $script:OriginalUserProfile
    # check-suppress:suppression_doc: fixture cleanup in test teardown; missing path is acceptable.
    Remove-Item -LiteralPath $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Get-VMGuestSshPublicKey' {
    It 'prefers static id_ed25519.pub over username templates' {
        $result = Get-VMGuestSshPublicKey -RepoRoot $RepoRoot -Username 'testuser'
        $result | Should -Be $StaticKey
    }

    It 'resolves ssh_personal_{username}.pub when static keys are absent' {
        Remove-Item -LiteralPath (Join-Path $FixtureSshDir 'id_ed25519.pub') -Force
        $result = Get-VMGuestSshPublicKey -RepoRoot $RepoRoot -Username 'testuser'
        $result | Should -Be $PersonalKey
    }

    It 'returns $null when no keys exist' {
        Remove-Item -LiteralPath (Join-Path $FixtureSshDir 'ssh_personal_testuser.pub') -Force
        $result = Get-VMGuestSshPublicKey -RepoRoot $RepoRoot -Username 'testuser'
        $result | Should -BeNullOrEmpty
    }

    It 'skips username templates when Username is empty' {
        Set-Content -Path (Join-Path $FixtureSshDir 'ssh_personal_testuser.pub') -Value $PersonalKey -NoNewline
        $result = Get-VMGuestSshPublicKey -RepoRoot $RepoRoot -Username ''
        $result | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-VMSetup wiring' {
    It 'dot-sources Get-VMGuestSshPublicKey.ps1' {
        $invokeVmSetupPath = Join-Path $RepoRoot 'src\platforms\Windows\modules\system\Invoke-VMSetup.ps1'
        $text = Get-Content -Raw -Path $invokeVmSetupPath
        $text | Should -Match 'Get-VMGuestSshPublicKey\.ps1'
    }

    It 'does not define Resolve-VMGuestSshKey inline' {
        $invokeVmSetupPath = Join-Path $RepoRoot 'src\platforms\Windows\modules\system\Invoke-VMSetup.ps1'
        $text = Get-Content -Raw -Path $invokeVmSetupPath
        $text | Should -Not -Match 'function Resolve-VMGuestSshKey'
    }
}
