<#
.SYNOPSIS
    Pester coverage for Invoke-PiSetup pi extension convergence.
.DESCRIPTION
    Drives the converger against a temp HOME with a recording "pi" shim on PATH
    and asserts: install specs carry the npm: scheme plus the lockfile version,
    an installed-but-undesired extension is removed, a version-drifted extension
    is reinstalled at the pinned version, and a missing desired-package registry
    is a hard error rather than a silent skip.
.NOTES
    Environment variables: (none — $HOME is overridden at script scope)
    Exit codes: 0 on success; 1 on failure
    The recording shim is written as pi.cmd on Windows and as an executable
    pi script elsewhere so the suite also runs on macOS/Linux.
#>

Describe 'Invoke-PiSetup pi extension convergence' {
    BeforeAll {
        Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\Format-NucleusOutput.psm1') -Force
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\ManagedPaths.ps1')
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\setup\Invoke-PiSetup.ps1')

        $script:realRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\..')).Path
        $script:lockfile = Get-Content -LiteralPath (Join-Path $script:realRepoRoot 'src\lockfiles\lockfile.json') -Raw | ConvertFrom-Json
        $script:registry = Get-Content -LiteralPath (Join-Path $script:realRepoRoot 'src\modules\packages\desired.json') -Raw | ConvertFrom-Json
        $script:hostKey = 'Windows'
        $script:desiredNames = @($script:registry.pi.$script:hostKey | ForEach-Object { $_.name })

        # Recording pi shim: appends its argv to $script:piLog and exits 0.
        $script:tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-pisetup-" + [guid]::NewGuid().ToString('N'))
        $script:shimDir = Join-Path $script:tempRoot 'shim'
        $script:homeRoot = Join-Path $script:tempRoot 'home'
        $null = New-Item -ItemType Directory -Path $script:shimDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $null = New-Item -ItemType Directory -Path $script:homeRoot -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $script:piLog = Join-Path $script:tempRoot 'pi-calls.log'

        if ($IsWindows) {
            $shimBody = "@echo off`r`necho %* >> `"$script:piLog`"`r`nexit /b 0`r`n"
            $null = Set-Content -Path (Join-Path $script:shimDir 'pi.cmd') -Value $shimBody -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
        } else {
            $shimBody = "#!/bin/sh`necho `"`$*`" >> '$script:piLog'`nexit 0`n"
            $shimPath = Join-Path $script:shimDir 'pi'
            $null = Set-Content -Path $shimPath -Value $shimBody -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
            [System.IO.File]::SetUnixFileMode($shimPath, [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite -bor [System.IO.UnixFileMode]::UserExecute)
        }

        $script:originalHome = $HOME
        $script:originalPath = $env:PATH
        Set-Variable -Name HOME -Value $script:homeRoot -Force
        $env:PATH = "$script:shimDir$([System.IO.Path]::PathSeparator)$env:PATH"

        function Initialize-PiSettingsRegistry {
            param([string[]]$Specs)
            $piAgentDir = Join-Path $script:homeRoot '.pi\agent'
            if (-not (Test-Path -LiteralPath $piAgentDir -PathType Container)) {
                $null = New-Item -ItemType Directory -Path $piAgentDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
            }
            $payload = @{ packages = @($Specs) } | ConvertTo-Json -Depth 5
            $null = Set-Content -Path (Join-Path $piAgentDir 'settings.json') -Value $payload -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
        }

        function Initialize-PiInstallRecord {
            param([hashtable]$Dependencies)
            $npmDir = Join-Path $script:homeRoot '.pi\agent\npm'
            if (-not (Test-Path -LiteralPath $npmDir -PathType Container)) {
                $null = New-Item -ItemType Directory -Path $npmDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
            }
            $payload = @{ dependencies = $Dependencies } | ConvertTo-Json -Depth 5
            $null = Set-Content -Path (Join-Path $npmDir 'package.json') -Value $payload -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
        }

        function Clear-PiState {
            if (Test-Path -LiteralPath $script:piLog) { Remove-Item -LiteralPath $script:piLog -Force }
            $piAgentDir = Join-Path $script:homeRoot '.pi'
            if (Test-Path -LiteralPath $piAgentDir) { Remove-Item -LiteralPath $piAgentDir -Recurse -Force }
        }

        function Get-PiCallList {
            if (-not (Test-Path -LiteralPath $script:piLog)) { return @() }
            return @(Get-Content -LiteralPath $script:piLog)
        }
    }
    AfterAll {
        Set-Variable -Name HOME -Value $script:originalHome -Force
        $env:PATH = $script:originalPath
        if ($script:tempRoot -and (Test-Path -LiteralPath $script:tempRoot)) {
            # check-suppress:suppression_doc: cleanup in test teardown -- failure is acceptable
            Remove-Item -LiteralPath $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'installs every desired extension with the npm: scheme and the lockfile version' {
        Clear-PiState
        Invoke-PiSetup

        $calls = Get-PiCallList
        $installCalls = @($calls | Where-Object { $_ -match '^install ' })
        $installCalls.Count | Should -Be $script:desiredNames.Count

        foreach ($name in $script:desiredNames) {
            $pin = $script:lockfile.pi.$name
            $installCalls | Should -Contain "install npm:$name@$pin --no-approve"
        }

        # A spec without the npm: scheme is rejected by pi's parser; never emit one.
        @($calls | Where-Object { $_ -match '^install ' -and $_ -notmatch '^install npm:' }) | Should -BeNullOrEmpty
    }

    It 'removes an installed extension that is absent from the desired list' {
        Clear-PiState
        Initialize-PiSettingsRegistry -Specs @('npm:pi-orphan@9.9.9')

        Invoke-PiSetup

        Get-PiCallList | Should -Contain 'remove npm:pi-orphan'
    }

    It 'reinstalls an extension whose installed version differs from the lockfile pin' {
        Clear-PiState
        $driftName = 'pi-memory'
        $pin = $script:lockfile.pi.$driftName
        Initialize-PiSettingsRegistry -Specs @("npm:$driftName@0.0.1")
        Initialize-PiInstallRecord -Dependencies @{ $driftName = '0.0.1' }

        Invoke-PiSetup

        Get-PiCallList | Should -Contain "install npm:$driftName@$pin --no-approve"
        # The installed-but-desired package must not be zapped.
        @(Get-PiCallList | Where-Object { $_ -eq "remove npm:$driftName" }) | Should -BeNullOrEmpty
    }

    It 'makes no pi calls when the machine is already converged' {
        Clear-PiState
        Initialize-PiSettingsRegistry -Specs @($script:desiredNames | ForEach-Object { "npm:$_@$($script:lockfile.pi.$_)" })
        $record = @{}
        foreach ($name in $script:desiredNames) { $record[$name] = $script:lockfile.pi.$name }
        Initialize-PiInstallRecord -Dependencies $record

        Invoke-PiSetup

        @(Get-PiCallList | Where-Object { $_ -match '^(install|remove) ' }) | Should -BeNullOrEmpty
    }

    It 'hard-errors when the desired-package registry is missing' {
        Clear-PiState
        # The module derives its repo root from its own location, so a copied
        # module inside a synthetic tree exercises the missing-file branch
        # without touching the real registry.
        $fakeRoot = Join-Path $script:tempRoot 'fakeroot'
        $fakeModuleDir = Join-Path $fakeRoot 'src\platforms\Windows\modules'
        $fakeSetupDir = Join-Path $fakeModuleDir 'setup'
        $null = New-Item -ItemType Directory -Path $fakeSetupDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        # The synthetic tree holds a lockfile but no desired-package registry, so
        # the registry check is the one that fires.
        $null = New-Item -ItemType Directory -Path (Join-Path $fakeRoot 'src\lockfiles') -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        Copy-Item -LiteralPath (Join-Path $script:realRepoRoot 'src\lockfiles\lockfile.json') -Destination (Join-Path $fakeRoot 'src\lockfiles\lockfile.json')
        Copy-Item -LiteralPath (Join-Path $script:realRepoRoot 'src\platforms\Windows\modules\Get-NucleusHostPlatform.ps1') -Destination (Join-Path $fakeModuleDir 'Get-NucleusHostPlatform.ps1')
        Copy-Item -LiteralPath (Join-Path $script:realRepoRoot 'src\platforms\Windows\modules\setup\Invoke-PiSetup.ps1') -Destination (Join-Path $fakeSetupDir 'Invoke-PiSetup.ps1')
        . (Join-Path $fakeSetupDir 'Invoke-PiSetup.ps1')

        { Invoke-PiSetup } | Should -Throw -ExpectedMessage '*desired package registry not found*'
        # A hard error must not fall through to installing anything.
        @(Get-PiCallList | Where-Object { $_ -match '^(install|remove) ' }) | Should -BeNullOrEmpty
    }
}
