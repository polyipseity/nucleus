<#
.SYNOPSIS
    Pester coverage for the superpowers branch of the lockfile enforcement probes.
.DESCRIPTION
    Drives Invoke-LockfileEnforcement with a fixture USER root and a real git
    checkout: a missing checkout, a directory that is not a git checkout, a
    checkout at the wrong revision and a checkout at the pinned revision.
.NOTES
    Environment variables: (none — %LOCALAPPDATA% is overridden at script scope)
    Exit codes: 0 on success; 1 on failure
    The suite runs on macOS/Linux as well; only the fixture paths differ.
#>

Describe 'Lockfile enforcement: superpowers checkout probe' {
    BeforeAll {
        $script:libDir = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\src\scripts\checks'
        . (Join-Path -Path $script:libDir -ChildPath 'lockfile-enforcement-lib.ps1')
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\src\platforms\Windows\modules\ManagedPaths.ps1')

        $script:tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-lfe-" + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:tempRoot -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup

        # Fixture checkout with one commit.
        $script:checkout = Join-Path (Join-Path $script:tempRoot 'localappdata') 'nucleus\plugins\superpowers'
        $null = New-Item -ItemType Directory -Path $script:checkout -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $null = Set-Content -Path (Join-Path $script:checkout 'README.md') -Value 'fixture' -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
        & git -C $script:checkout init --quiet
        & git -C $script:checkout -c user.email=test@example.invalid -c user.name=Test add -A
        & git -C $script:checkout -c user.email=test@example.invalid -c user.name=Test commit --quiet -m 'fixture'
        $script:checkoutRev = (& git -C $script:checkout rev-parse HEAD | Select-Object -First 1).Trim()

        # The probe library reads Windows USER-root paths; both variables are
        # overridden so the suite also runs on macOS/Linux.
        $script:originalLocalAppData = $env:LOCALAPPDATA
        $script:originalUserProfile = $env:USERPROFILE
        $env:LOCALAPPDATA = Join-Path $script:tempRoot 'localappdata'
        $env:USERPROFILE = $script:tempRoot

        function Invoke-SuperpowersProbe {
            param([string]$Rev)
            $script:errors = @()
            $script:infos = @()
            $lockfile = @{ cursor = @{ superpowers = @{ source = 'https://example.invalid/superpowers.git'; rev = $Rev } } }
            $null = Invoke-LockfileEnforcement -Lockfile $lockfile `
                -InfoFn { param($m) $script:infos += $m } `
                -WarnFn { param($m) $script:warnings = @($script:warnings) + $m } `
                -ErrorFn { param($m) $script:errors += $m }
            return @{ Errors = $script:errors; Infos = $script:infos }
        }
    }
    AfterAll {
        $env:LOCALAPPDATA = $script:originalLocalAppData
        $env:USERPROFILE = $script:originalUserProfile
        if ($script:tempRoot -and (Test-Path -LiteralPath $script:tempRoot)) {
            # check-suppress:suppression_doc: cleanup in test teardown -- failure is acceptable
            Remove-Item -LiteralPath $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports an error when the checkout is missing' {
        Rename-Item -LiteralPath $script:checkout -NewName 'superpowers-hidden'
        try {
            $result = Invoke-SuperpowersProbe -Rev $script:checkoutRev
            @($result.Errors | Where-Object { $_ -match 'plugin checkout not found' }).Count | Should -Be 1
        } finally {
            Rename-Item -LiteralPath (Join-Path (Split-Path -Path $script:checkout -Parent) 'superpowers-hidden') -NewName 'superpowers'
        }
    }

    It 'reports an error when the path is not a git checkout' {
        $gitDir = Join-Path $script:checkout '.git'
        Rename-Item -LiteralPath $gitDir -NewName '.git-hidden'
        try {
            $result = Invoke-SuperpowersProbe -Rev $script:checkoutRev
            @($result.Errors | Where-Object { $_ -match 'is not a managed git checkout' }).Count | Should -Be 1
        } finally {
            Rename-Item -LiteralPath (Join-Path $script:checkout '.git-hidden') -NewName '.git'
        }
    }

    It 'reports an error when the checkout is at the wrong revision' {
        $result = Invoke-SuperpowersProbe -Rev '0000000000000000000000000000000000000000'
        @($result.Errors | Where-Object { $_ -match 'checkout is at' }).Count | Should -Be 1
    }

    It 'reports the checkout as present when it matches the pin' {
        $result = Invoke-SuperpowersProbe -Rev $script:checkoutRev
        @($result.Infos | Where-Object { $_ -match 'checkout present at' }).Count | Should -Be 1
        @($result.Errors | Where-Object { $_ -match 'superpowers' }).Count | Should -Be 0
    }
}
