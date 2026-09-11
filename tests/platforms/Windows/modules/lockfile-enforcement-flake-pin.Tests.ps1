<#
.SYNOPSIS
    Pester coverage for the flake-pinned uv revision probe.
.DESCRIPTION
    A tool declared with "pin": "flake:<node>" in src/modules/packages/desired.json
    is installed from a git revision, so the enforcement lib cannot compare a
    version: it compares the commit uv recorded for the install (PEP 610
    direct_url.json) against the revision in src/flake.lock.

    The suite drives the lib from a synthetic repo root holding a fixture
    registry and flake lock, with a recording "uv" shim on PATH and an isolated
    UV_TOOL_DIR, and asserts: a matching revision is clean, a drifted revision is
    reported, a missing install record is reported, an unsupported pin shape is
    reported, and a lockfile entry that this host does not declare is not probed.
.NOTES
    Environment variables: NUCLEUS_HOST / NUCLEUS_REPO_ROOT / HOME / UV_TOOL_DIR
    are redirected for the duration of the run and restored in AfterAll.
    Exit codes: 0 on success; 1 on failure
#>

Describe 'lockfile enforcement flake-pinned revisions' {
    BeforeAll {
        $script:realRepoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..')).Path
        $script:rev = '29112bef099274229cadff79cdff7bf7b99c4b77'

        $script:tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-flakepin-" + [guid]::NewGuid().ToString('N'))
        $script:fakeRoot = Join-Path $script:tempRoot 'repo'
        $script:shimDir = Join-Path $script:tempRoot 'shim'
        $script:toolDir = Join-Path $script:tempRoot 'uvtools'
        $script:distInfo = Join-Path $script:toolDir 'hermes-agent\Lib\site-packages\hermes_agent-0.21.0.dist-info'
        $null = New-Item -ItemType Directory -Path $script:shimDir, $script:distInfo -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup

        # Synthetic repo root: the lib derives its root from its own location, so
        # only the files it reads need to exist.
        foreach ($relative in @(
                'src\scripts\checks\lockfile-enforcement-lib.ps1',
                'src\platforms\Windows\modules\ManagedPaths.ps1',
                'src\platforms\Windows\modules\Get-NucleusHostPlatform.ps1',
                'src\platforms\Windows\modules\lib\Resolve-NucleusFlakePin.ps1',
                'src\modules\host-platform-registry.json')) {
            $target = Join-Path $script:fakeRoot $relative
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
            Copy-Item -LiteralPath (Join-Path $script:realRepoRoot $relative) -Destination $target
        }

        $registryPath = Join-Path $script:fakeRoot 'src\modules\packages\desired.json'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $registryPath) -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $registry = @{
            '$schema' = './desired.schema.json'
            uv        = @{
                Windows  = @(@{ name = 'paddleocr' }, @{ name = 'hermes-agent'; pin = 'flake:hermes-agent' })
                MacBook  = @(@{ name = 'paddleocr' })
                NixOS    = @(@{ name = 'paddleocr' })
            }
        }
        $null = Set-Content -LiteralPath $registryPath -Value ($registry | ConvertTo-Json -Depth 6)  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup

        $flakeLock = @{
            nodes = @{
                'hermes-agent' = @{ locked = @{ type = 'github'; owner = 'NousResearch'; repo = 'hermes-agent'; rev = $script:rev } }
            }
        }
        $null = Set-Content -LiteralPath (Join-Path $script:fakeRoot 'src\flake.lock') -Value ($flakeLock | ConvertTo-Json -Depth 6)  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup

        # Recording uv shim: reports the version-pinned tool so the version probe
        # stays quiet, and ignores everything else.
        if ($IsWindows) {
            $null = Set-Content -LiteralPath (Join-Path $script:shimDir 'uv.cmd') -Value "@echo off`r`necho paddleocr v3.6.0`r`nexit /b 0`r`n" -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
        } else {
            $uvShim = Join-Path $script:shimDir 'uv'
            $null = Set-Content -LiteralPath $uvShim -Value "#!/bin/sh`necho 'paddleocr v3.6.0'`nexit 0`n" -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
            [System.IO.File]::SetUnixFileMode($uvShim, [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite -bor [System.IO.UnixFileMode]::UserExecute)
        }

        $script:originalEnv = @{
            Host        = $env:NUCLEUS_HOST
            RepoRoot    = $env:NUCLEUS_REPO_ROOT
            Home        = $HOME
            UserProfile = $env:USERPROFILE
            UvToolDir   = $env:UV_TOOL_DIR
            Path        = $env:PATH
        }
        $env:NUCLEUS_HOST = 'Windows'
        $env:NUCLEUS_REPO_ROOT = $script:fakeRoot
        # The lib reads the bun global record through USERPROFILE, which does not
        # exist on POSIX hosts; point it at the isolated temp home.
        $env:USERPROFILE = $script:tempRoot
        $env:UV_TOOL_DIR = $script:toolDir
        Set-Variable -Name HOME -Value $script:tempRoot -Force
        $env:PATH = "$script:shimDir$([System.IO.Path]::PathSeparator)$env:PATH"

        # A lockfile whose uv section also carries an entry this host does not
        # declare, which must not be probed.
        $script:Lockfile = @{
            uv = @{ paddleocr = '3.6.0'; 'foreign-only' = '1.0.0' }
        }

        . (Join-Path $script:fakeRoot 'src\scripts\checks\lockfile-enforcement-lib.ps1')

        function Invoke-Probe {
            $script:errors = [System.Collections.Generic.List[string]]::new()
            $script:infos = [System.Collections.Generic.List[string]]::new()
            $result = Invoke-LockfileEnforcement -Lockfile $script:Lockfile `
                -InfoFn { param($m) $script:infos.Add($m) } `
                -WarnFn { param($m) $script:infos.Add($m) } `
                -ErrorFn { param($m) $script:errors.Add($m) }
            return $result
        }

        function Write-InstalledCommit {
            param([string]$Commit)
            $payload = @{ vcs_info = @{ commit_id = $Commit; vcs = 'git' } } | ConvertTo-Json -Depth 5
            $null = Set-Content -LiteralPath (Join-Path $script:distInfo 'direct_url.json') -Value $payload  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
        }
    }
    AfterAll {
        $env:NUCLEUS_HOST = $script:originalEnv.Host
        $env:NUCLEUS_REPO_ROOT = $script:originalEnv.RepoRoot
        $env:USERPROFILE = $script:originalEnv.UserProfile
        $env:UV_TOOL_DIR = $script:originalEnv.UvToolDir
        Set-Variable -Name HOME -Value $script:originalEnv.Home -Force
        $env:PATH = $script:originalEnv.Path
        if ($script:tempRoot -and (Test-Path -LiteralPath $script:tempRoot)) {
            # check-suppress:suppression_doc: cleanup in test teardown -- failure is acceptable
            Remove-Item -LiteralPath $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports no drift when the recorded commit matches the flake revision' {
        Write-InstalledCommit -Commit $script:rev
        $null = Invoke-Probe  # check-suppress:suppression_doc: the exit count is asserted through the captured error list
        $script:errors | Should -BeNullOrEmpty
    }

    It 'reports drift when the recorded commit differs from the flake revision' {
        Write-InstalledCommit -Commit 'deadbeef'
        $null = Invoke-Probe  # check-suppress:suppression_doc: the exit count is asserted through the captured error list
        @($script:errors) | Should -HaveCount 1
        $script:errors[0] | Should -BeLike "*expected revision $($script:rev), installed deadbeef*"
    }

    It 'reports drift when the install record is missing' {
        Remove-Item -LiteralPath (Join-Path $script:distInfo 'direct_url.json') -Force
        $null = Invoke-Probe  # check-suppress:suppression_doc: the exit count is asserted through the captured error list
        @($script:errors) | Should -HaveCount 1
        $script:errors[0] | Should -BeLike '*no install record*'
    }

    It 'reports an unsupported pin shape' {
        $registryPath = Join-Path $script:fakeRoot 'src\modules\packages\desired.json'
        $broken = @{ uv = @{ Windows = @(@{ name = 'hermes-agent'; pin = 'npm:hermes-agent' }); MacBook = @(); NixOS = @() } }
        $null = Set-Content -LiteralPath $registryPath -Value ($broken | ConvertTo-Json -Depth 6)  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
        try {
            $null = Invoke-Probe  # check-suppress:suppression_doc: the exit count is asserted through the captured error list
            @($script:errors) | Should -HaveCount 1
            $script:errors[0] | Should -BeLike "*unsupported pin 'npm:hermes-agent'*"
        } finally {
            $null = Set-Content -LiteralPath $registryPath -Value (@{ uv = @{ Windows = @(@{ name = 'paddleocr' }, @{ name = 'hermes-agent'; pin = 'flake:hermes-agent' }); MacBook = @(@{ name = 'paddleocr' }); NixOS = @(@{ name = 'paddleocr' }) } } | ConvertTo-Json -Depth 6)  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
        }
    }

    It 'does not probe a lockfile entry this host does not declare' {
        # paddleocr is declared (and installed per the shim); foreign-only is not
        # declared for any host and must stay silent.
        Write-InstalledCommit -Commit $script:rev
        $null = Invoke-Probe  # check-suppress:suppression_doc: the exit count is asserted through the captured error list
        $script:errors | Should -BeNullOrEmpty
        @($script:infos | Where-Object { $_ -like '*foreign-only*' }) | Should -BeNullOrEmpty
    }
}
