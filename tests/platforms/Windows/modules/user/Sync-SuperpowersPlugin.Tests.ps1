<#
.SYNOPSIS
    Pester coverage for the superpowers plugin checkout and its pi / opencode links.
.DESCRIPTION
    Drives Sync-SuperpowersPlugin against a fixture origin repository, a temp
    HOME and a temp %LOCALAPPDATA% USER root: clone-at-pin, idempotent re-run,
    wrong-target relink, refusal to overwrite a foreign file, hard failure when
    the pin cannot be fetched, and disable-path cleanup.
.NOTES
    Environment variables: (none — $HOME and %LOCALAPPDATA% are overridden at script scope)
    Exit codes: 0 on success; 1 on failure
    Symlink creation requires elevation or Developer Mode on Windows; not
    required on macOS/Linux where the tests also run.  icacls is shimmed off
    Windows.
#>

Describe 'Sync-SuperpowersPlugin plugin checkout and links' {
    BeforeAll {
        Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\Format-NucleusOutput.psm1') -Force
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\ManagedPaths.ps1')
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\user\Sync-SuperpowersPlugin.ps1')

        # The delete-protection module shells out to icacls, which only exists on
        # Windows; the shim keeps the suite runnable on macOS/Linux.
        function icacls { $global:LASTEXITCODE = 0 }

        $script:tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-superpowers-" + [guid]::NewGuid().ToString('N'))
        $script:homeRoot = Join-Path $script:tempRoot 'home'
        $script:localAppData = Join-Path $script:tempRoot 'localappdata'
        $script:repoRoot = Join-Path $script:tempRoot 'repo'
        $null = New-Item -ItemType Directory -Path $script:homeRoot -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $null = New-Item -ItemType Directory -Path $script:localAppData -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $null = New-Item -ItemType Directory -Path (Join-Path $script:repoRoot 'src\lockfiles') -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup

        # Fixture origin repository with a single commit to pin.
        $script:origin = Join-Path $script:tempRoot 'origin'
        $null = New-Item -ItemType Directory -Path (Join-Path $script:origin '.pi\extensions') -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $null = New-Item -ItemType Directory -Path (Join-Path $script:origin '.opencode\plugins') -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $null = Set-Content -Path (Join-Path $script:origin '.pi\extensions\superpowers.ts') -Value 'export {}' -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
        $null = Set-Content -Path (Join-Path $script:origin '.opencode\plugins\superpowers.js') -Value 'export {}' -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
        & git -C $script:origin init --quiet
        & git -C $script:origin -c user.email=test@example.invalid -c user.name=Test add -A
        & git -C $script:origin -c user.email=test@example.invalid -c user.name=Test commit --quiet -m 'fixture'
        $script:pinnedRev = (& git -C $script:origin rev-parse HEAD | Select-Object -First 1).Trim()

        function Write-FixtureLockfile {
            param([string]$Source, [string]$Rev)
            $payload = @{ cursor = @{ superpowers = @{ source = $Source; rev = $Rev } } } | ConvertTo-Json -Depth 6
            $null = Set-Content -Path (Join-Path $script:repoRoot 'src\lockfiles\lockfile.json') -Value $payload -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
        }
        Write-FixtureLockfile -Source $script:origin -Rev $script:pinnedRev

        $script:pluginDir = Join-Path $script:localAppData 'nucleus\plugins\superpowers'
        $script:piLink = Join-Path $script:homeRoot '.pi\agent\extensions\superpowers.ts'
        $script:opencodeLink = Join-Path $script:homeRoot '.opencode\plugins\superpowers'
        $script:piTarget = Join-Path $script:pluginDir '.pi\extensions\superpowers.ts'
        $script:opencodeTarget = Join-Path $script:pluginDir '.opencode\plugins\superpowers.js'

        $script:originalHome = $HOME
        $script:originalLocalAppData = $env:LOCALAPPDATA
        Set-Variable -Name HOME -Value $script:homeRoot -Force
        $env:LOCALAPPDATA = $script:localAppData

        function Initialize-SuperpowersFixture {
            foreach ($path in @($script:pluginDir, (Join-Path $script:homeRoot '.pi'), (Join-Path $script:homeRoot '.opencode'))) {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
            }
            Write-FixtureLockfile -Source $script:origin -Rev $script:pinnedRev
        }
    }
    AfterAll {
        Set-Variable -Name HOME -Value $script:originalHome -Force
        $env:LOCALAPPDATA = $script:originalLocalAppData
        if ($script:tempRoot -and (Test-Path -LiteralPath $script:tempRoot)) {
            # check-suppress:suppression_doc: cleanup in test teardown -- failure is acceptable
            Remove-Item -LiteralPath $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'clones the pinned revision and links it for pi and opencode' {
        Initialize-SuperpowersFixture

        Sync-SuperpowersPlugin -RepoRoot $script:repoRoot -Enabled:$true

        (Test-Path -LiteralPath (Join-Path $script:pluginDir '.git')) | Should -Be $true
        $head = (& git -C $script:pluginDir rev-parse HEAD | Select-Object -First 1).Trim()
        $head | Should -Be $script:pinnedRev

        (Get-Item -LiteralPath $script:piLink -Force).Target | Should -Be $script:piTarget
        (Get-Item -LiteralPath $script:opencodeLink -Force).Target | Should -Be $script:opencodeTarget
    }

    It 'is a no-op when the checkout is already at the pinned revision' {
        Initialize-SuperpowersFixture
        Sync-SuperpowersPlugin -RepoRoot $script:repoRoot -Enabled:$true

        # Make the remote unreachable: a re-fetch would now fail, so surviving the
        # second run proves the converged checkout was left alone.
        $hiddenOrigin = "$script:origin-hidden"
        Rename-Item -LiteralPath $script:origin -NewName (Split-Path -Path $hiddenOrigin -Leaf)
        try {
            { Sync-SuperpowersPlugin -RepoRoot $script:repoRoot -Enabled:$true } | Should -Not -Throw
        } finally {
            Rename-Item -LiteralPath $hiddenOrigin -NewName (Split-Path -Path $script:origin -Leaf)
        }

        $head = (& git -C $script:pluginDir rev-parse HEAD | Select-Object -First 1).Trim()
        $head | Should -Be $script:pinnedRev
    }

    It 'relinks a symlink that points at the wrong target' {
        Initialize-SuperpowersFixture
        Sync-SuperpowersPlugin -RepoRoot $script:repoRoot -Enabled:$true
        Remove-Item -LiteralPath $script:piLink -Force
        $null = New-Item -ItemType SymbolicLink -Path $script:piLink -Target (Join-Path $script:homeRoot 'stale.ts')  # check-suppress:suppression_doc: New-Item returns FileInfo, discarded in test setup

        Sync-SuperpowersPlugin -RepoRoot $script:repoRoot -Enabled:$true

        (Get-Item -LiteralPath $script:piLink -Force).Target | Should -Be $script:piTarget
    }

    It 'refuses to overwrite a foreign file at a link path' {
        Initialize-SuperpowersFixture
        Sync-SuperpowersPlugin -RepoRoot $script:repoRoot -Enabled:$true
        Remove-Item -LiteralPath $script:piLink -Force
        $null = Set-Content -Path $script:piLink -Value 'user data' -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup

        { Sync-SuperpowersPlugin -RepoRoot $script:repoRoot -Enabled:$true } | Should -Throw
        (Get-Content -LiteralPath $script:piLink -Raw) | Should -Be 'user data'
    }

    It 'fails hard when the pinned revision cannot be fetched' {
        Initialize-SuperpowersFixture
        Write-FixtureLockfile -Source (Join-Path $script:tempRoot 'missing-origin') -Rev $script:pinnedRev

        { Sync-SuperpowersPlugin -RepoRoot $script:repoRoot -Enabled:$true } | Should -Throw
    }

    It 'fails hard when the lockfile is missing' {
        Initialize-SuperpowersFixture
        Remove-Item -LiteralPath (Join-Path $script:repoRoot 'src\lockfiles\lockfile.json') -Force

        { Sync-SuperpowersPlugin -RepoRoot $script:repoRoot -Enabled:$true } | Should -Throw
    }

    It 'removes only the managed links and checkout when disabled' {
        Initialize-SuperpowersFixture
        Sync-SuperpowersPlugin -RepoRoot $script:repoRoot -Enabled:$true

        Sync-SuperpowersPlugin -RepoRoot $script:repoRoot -Enabled:$false

        (Test-Path -LiteralPath $script:piLink) | Should -Be $false
        (Test-Path -LiteralPath $script:opencodeLink) | Should -Be $false
        (Test-Path -LiteralPath $script:pluginDir) | Should -Be $false
    }
}
