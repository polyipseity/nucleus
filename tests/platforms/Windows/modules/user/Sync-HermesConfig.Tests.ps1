<#
.SYNOPSIS
    Pester coverage for the harness-bridge plugin link in Sync-HermesConfig.ps1.

.DESCRIPTION
    Unit-tests the plugin deployment on temp paths. HERMES_HOME is the
    authoritative resolver for the CLI's config and user-data home, including
    profiles, so the suite asserts that nucleus pins it to the managed
    ~/.hermes root and links the plugin there: an enabled run links the
    overlay-resolved source, a second run is idempotent, a link pointing
    elsewhere is recreated, a real directory is refused without being deleted,
    and a disabled run removes the managed link.

    The hermes CLI is absent throughout, so the enable half stops at its
    documented warning; the CLI contract is probed separately against the real
    binary.

.NOTES
    Environment variables: $HOME and $LOCALAPPDATA are overridden at script scope
    Exit codes: 0 on success; 1 on failure
    Symlink creation requires elevation or Developer Mode on Windows; not
    required on macOS/Linux where the tests also run.
#>

# WHY: fixture cleanup must not depend on the interactive profile's safe-delete
# wrapper; these paths are all built from this suite's temp roots.
function Clear-HermesTestPath {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.LinkType -eq 'SymbolicLink') {
        [System.IO.File]::Delete($Path)
    } elseif ($item.PSIsContainer) {
        [System.IO.Directory]::Delete($Path, $true)
    } else {
        [System.IO.File]::Delete($Path)
    }
}

Describe 'Sync-HermesConfig harness-bridge plugin link' {
    BeforeAll {
        Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\Format-NucleusOutput.psm1') -Force
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\ConfigHelpers.ps1')
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\user\Sync-HermesConfig.ps1')

        # Fixture tree: the per-user overlay falls back to src/users/default/.
        $script:repoRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-hermescfg-" + [guid]::NewGuid().ToString('N'))
        $script:homeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-hermeshome-" + [guid]::NewGuid().ToString('N'))
        $pluginSourceDir = Join-Path $script:repoRoot 'src\users\default\hermes\plugins\harness-bridge'
        $null = New-Item -ItemType Directory -Path $pluginSourceDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $null = Set-Content -Path (Join-Path $pluginSourceDir 'plugin.yaml') -Value 'name: harness-bridge' -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
        $script:pluginSource = $pluginSourceDir

        # The same first-level overlay entries POSIX seeds before gateway start.
        # The catalog is read from the real default domain, then extended with
        # entries that must not reach either .env file.
        $script:hermesSkillNames = @(
            'nucleus-citation-reference', 'nucleus-harness-reference',
            'nucleus-platform-reference', 'nucleus-policy-reference',
            'nucleus-service-reference', 'nucleus-vm-reference'
        )
        $hermesOverlay = Join-Path $script:repoRoot 'src\users\default\hermes'
        foreach ($relative in @('config.yaml', 'SOUL.md', 'profiles\gateway\config.yaml')) {
            $path = Join-Path $hermesOverlay $relative
            $null = New-Item -ItemType Directory -Path (Split-Path -Path $path -Parent) -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
            $null = Set-Content -Path $path -Value ("fixture: $relative") -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
        }
        $script:hermesSkillsOverlay = Join-Path $hermesOverlay 'skills'
        $null = New-Item -ItemType Directory -Path $script:hermesSkillsOverlay -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $script:hermesGatewaySkillSources = @{}
        $gatewaySkillsHome = Join-Path (Join-Path (Join-Path $script:homeRoot '.hermes') 'profiles\gateway') 'skills'
        foreach ($name in $script:hermesSkillNames) {
            $source = Join-Path $script:repoRoot "src\users\default\agents\skills\$name"
            $null = New-Item -ItemType Directory -Path $source -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
            $script:hermesGatewaySkillSources[(Join-Path $gatewaySkillsHome $name)] = $source
        }

        $defaultCatalogPath = Join-Path $PSScriptRoot '..\..\..\..\..\src\users\default\env-secrets.json'
        $script:hermesCatalogSecrets = @(
            (Get-Content -Raw -LiteralPath $defaultCatalogPath | ConvertFrom-Json).secrets |
                Where-Object { @($_.consumers) -contains 'hermes-agent' -and $_.sopsSource -eq 'user' }
        )
        $fixtureCatalogSecrets = @($script:hermesCatalogSecrets) + @(
            [pscustomobject]@{ name = 'env_hermes_system_probe'; envVar = 'SYSTEM_PROBE'; sopsSource = 'system'; consumers = @('hermes-agent') }
            [pscustomobject]@{ name = 'env_unrelated_probe'; envVar = 'UNRELATED_PROBE'; sopsSource = 'user'; consumers = @('other') }
        )
        $null = Set-Content -Path (Join-Path $script:repoRoot 'src\users\default\env-secrets.json') -Value ([pscustomobject]@{ secrets = $fixtureCatalogSecrets } | ConvertTo-Json -Depth 5) -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup

        # Stand in for SOPS decryption: values are derived from the catalog, so
        # the assertion proves the catalog selects the rendered lines.
        $script:hermesDecryptedSecrets = @{}
        foreach ($entry in $fixtureCatalogSecrets) {
            $script:hermesDecryptedSecrets[$entry.name] = "fixture:$($entry.name)"
        }
        $script:hermesExpectedEnvLines = @($script:hermesCatalogSecrets | ForEach-Object { "$($_.envVar)=fixture:$($_.name)" })
        $script:hermesDecryptCalls = @()
        function Get-HermesDecryptedUserSecret {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)][string]$RepoRoot,
                [Parameter(Mandatory)][string]$User
            )
            $script:hermesDecryptCalls += "$RepoRoot|$User"
            return [PSCustomObject]$script:hermesDecryptedSecrets
        }

        # The install branch reads its playwright pin from the lockfile, the same
        # path Sync-HermesConfig uses on a real host.
        $lockfileDir = Join-Path $script:repoRoot 'src\lockfiles'
        $null = New-Item -ItemType Directory -Path $lockfileDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $lockfile = [ordered]@{ bun = [ordered]@{ playwright = '1.63.0' } }
        Set-Content -Path (Join-Path $lockfileDir 'lockfile.json') -Value ($lockfile | ConvertTo-Json -Depth 4)  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup

        $script:localAppData = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-hermeslad-" + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:homeRoot -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $null = New-Item -ItemType Directory -Path $script:localAppData -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $script:managedHermesHome = Join-Path $script:homeRoot '.hermes'
        $script:pluginLink = Join-Path (Join-Path $script:managedHermesHome 'plugins') 'harness-bridge'

        # Paths whose existence and content are snapshotted when the Run value
        # is requested. The home symlink is created by Sync-HermesConfig itself.
        $hermesHome = $script:managedHermesHome
        $gatewayHome = Join-Path $hermesHome 'profiles\gateway'
        $script:hermesCliSkillsPath = Join-Path $hermesHome 'skills'
        $script:hermesRepoLink = Join-Path $hermesHome 'repo'
        $script:hermesManagedFileLinks = @(
            (Join-Path $hermesHome 'config.yaml'),
            (Join-Path $hermesHome 'SOUL.md'),
            (Join-Path $gatewayHome 'config.yaml'),
            (Join-Path $gatewayHome 'SOUL.md')
        )
        $script:hermesEnvPaths = @(
            (Join-Path $hermesHome '.env'),
            (Join-Path $gatewayHome '.env')
        )
        $script:hermesLinkPaths = @(
            (Join-Path $hermesHome 'config.yaml'),
            (Join-Path $hermesHome 'SOUL.md'),
            $script:hermesCliSkillsPath,
            $script:hermesRepoLink,
            (Join-Path $gatewayHome 'config.yaml'),
            (Join-Path $gatewayHome 'SOUL.md'),
            (Join-Path $gatewayHome 'skills')
        ) + @($script:hermesGatewaySkillSources.Keys)

        # A stand-in hermes CLI lets the autostart case reach the plugin gate
        # without leaving the test host; an enabled plugin needs no further
        # calls. The real CLI contract is verified separately on a real host.
        $script:standInHermes = Join-Path $script:homeRoot 'stand-in-hermes'
        if ($IsWindows) {
            $script:standInHermes = "$($script:standInHermes).cmd"
            Set-Content -Path $script:standInHermes -Value @('@echo Status: enabled', 'exit /b 0')  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
        } else {
            Set-Content -Path $script:standInHermes -Value @('#!/bin/sh', 'echo "Status: enabled"', 'exit 0')  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
            $null = & chmod 755 $script:standInHermes  # check-suppress:suppression_doc: chmod returns nothing; the exit status is not the subject of this setup
        }

        $script:originalHome = $HOME
        $script:originalLocalAppData = $env:LOCALAPPDATA
        $script:originalAppData = $env:APPDATA
        $script:originalHermesHome = $env:HERMES_HOME
        Set-Variable -Name HOME -Value $script:homeRoot -Force
        # WHY here: Sync-HermesConfig reads $HOME for the Playwright cache, and with
        #   no chromium-* present the real installer runs, which downloads from npm
        #   in the middle of a unit test. The child path string matches the one the
        #   module builds so the probe matches on every platform.
        $null = New-Item -ItemType Directory -Path (Join-Path -Path (Join-Path -Path $script:homeRoot -ChildPath '.cache\ms-playwright') -ChildPath 'chromium-1194') -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $env:LOCALAPPDATA = $script:localAppData
        # The startup-folder sweep joins $env:APPDATA, which is Windows-only.
        $script:appData = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-hermesappdata-" + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:appData -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $env:APPDATA = $script:appData

        # Save-BunRecorder - a stand-in bun that records the arguments it was
        # handed, so the install call can be asserted without running playwright.
        #
        # WHY two implementations: the call operator runs a file, not a command
        #   line, so the stand-in has to be something the host can execute. Same
        #   shape as the rclone stand-in, for the same reason.
        $script:BunRecordPath = Join-Path $script:homeRoot 'bun-args.txt'
        function Save-BunRecorder {
            $path = Join-Path -Path $script:homeRoot -ChildPath 'stand-in-bun'
            if ($IsWindows) {
                $path = "$path.cmd"
                Set-Content -Path $path -Value @('@echo off', ('echo %* > "{0}"' -f $script:BunRecordPath), 'exit /b 0')  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
                return $path
            }
            Set-Content -Path $path -Value @('#!/bin/sh', ('echo "$*" > "{0}"' -f $script:BunRecordPath), 'exit 0')  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
            $null = & chmod 755 $path  # check-suppress:suppression_doc: chmod returns nothing; the exit status is not the subject of this setup
            return $path
        }

        # The symlink privilege probe, the User-scope environment writes, the
        # hermes CLI lookup, and the delete-protection helpers are all stubbed so
        # nothing touches the real machine.  Get-Command itself is left alone:
        # Pester resolves mocked commands through it.
        $script:hermesEnvWrites = @{}
        $script:hermesProtection = @{}
        $script:hermesProtectionEvents = @()
        Mock Test-HermesSymlinkPrivilege { return $true }
        Mock Get-HermesUserEnvVar { return $null }
        Mock Write-HermesUserEnvVar { $script:hermesEnvWrites[$Name] = $Value }
        Mock Set-ManagedSymlinkDeleteProtection {
            $script:hermesProtection[$Path] = $true
            $script:hermesProtectionEvents += "set:$Path"
        }
        Mock Remove-ManagedSymlinkDeleteProtection {
            $script:hermesProtection[$Path] = $false
            $script:hermesProtectionEvents += "remove:$Path"
        }

        # hermes is not installed in this sandbox: the enable half warns and stops.
        Mock Get-HermesCliPath { return $null }
        Mock Get-HermesBunPath { return $null }
        Mock Get-HermesGatewayService { return $null }
        Mock Get-HermesGatewayTask { return $null }

        # WHY: SCM changes and HKCU writes or removals cannot run on the test
        # host. Mocking the module's boundary commands to these recorders
        # captures the arguments without touching the machine. The Invoke- verbs
        # keep the local recorders out of PSSA's state-changing-function rule.
        $script:scmRemovals = 0
        $script:runValues = @{}
        $script:runValueRemovals = @()
        function Invoke-HermesGatewayServiceRemoval { $script:scmRemovals++ }
        function Invoke-HermesGatewayRunValueWrite {
            param([string]$Name, [string]$Command)
            $script:runValues[$Name] = $Command
            # WHY snapshot here: the profile has to exist before autostart is
            # written, so the Run mock is the observation point for call order.
            if ($Name -eq 'nucleus-hermes-gateway') {
                $links = @{}
                foreach ($path in $script:hermesLinkPaths) {
                    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                    if ($null -ne $item) { $links[$path] = $item }
                }
                $envFiles = @{}
                foreach ($path in $script:hermesEnvPaths) {
                    if (Test-Path -LiteralPath $path -PathType Leaf) {
                        $envFiles[$path] = Get-Content -LiteralPath $path -Raw
                    }
                }
                $script:runTimeHermesLayout = @{ Links = $links; EnvFiles = $envFiles }
            }
        }
        function Invoke-HermesGatewayRunValueRemoval {
            param([string]$Name)
            $script:runValueRemovals += $Name
        }
        Mock Remove-HermesGatewayService { Invoke-HermesGatewayServiceRemoval }
        Mock Set-HermesGatewayRunValue { Invoke-HermesGatewayRunValueWrite -Name $Name -Command $Command }
        Mock Remove-HermesGatewayRunValue { Invoke-HermesGatewayRunValueRemoval -Name $Name }
    }

    AfterAll {
        Set-Variable -Name HOME -Value $script:originalHome -Force
        $env:LOCALAPPDATA = $script:originalLocalAppData
        $env:APPDATA = $script:originalAppData
        $env:HERMES_HOME = $script:originalHermesHome
        foreach ($path in @($script:repoRoot, $script:homeRoot, $script:localAppData, $script:appData)) {
            if ($path) { Clear-HermesTestPath -Path $path }
        }
    }

    BeforeEach {
        $script:scmRemovals = 0
        $script:runValues = @{}
        $script:hermesEnvWrites = @{}
        $script:hermesProtection = @{}
        $script:hermesProtectionEvents = @()
        $script:runValueRemovals = @()
        $script:runTimeHermesLayout = $null
        $script:hermesDecryptCalls = @()
        Clear-HermesTestPath -Path $script:pluginLink
    }

    It 'replaces the SCM service with a per-user gateway Run value' {
        Mock Get-HermesCliPath { return $script:standInHermes }
        Sync-HermesConfig -Enabled:$true -User 'testuser' -RepoRoot $script:repoRoot > $null

        $script:scmRemovals | Should -Be 1
        $script:runValues['nucleus-hermes-gateway'] | Should -Be 'hermes --profile gateway gateway run --replace'
    }

    It 'pins HERMES_HOME to the managed ~/.hermes root' {
        Sync-HermesConfig -Enabled:$true -User 'testuser' -RepoRoot $script:repoRoot > $null

        $script:hermesEnvWrites['HERMES_HOME'] | Should -Be $script:managedHermesHome
        $env:HERMES_HOME | Should -Be $script:managedHermesHome
        (Get-Item -LiteralPath $script:pluginLink -Force).Target | Should -Be $script:pluginSource
        Test-Path -LiteralPath (Join-Path $script:localAppData 'hermes\plugins\harness-bridge') | Should -Be $false
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

    It 'removes the gateway Run value exactly once when disabled' {
        Sync-HermesConfig -Enabled:$false -User 'testuser' -RepoRoot $script:repoRoot > $null

        $script:runValueRemovals.Count | Should -Be 1
        $script:runValueRemovals[0] | Should -Be 'nucleus-hermes-gateway'
    }

    It 'clears delete protection before redeploying managed file links on a second activation' {
        Sync-HermesConfig -Enabled:$true -User 'testuser' -RepoRoot $script:repoRoot > $null
        $firstEventCount = $script:hermesProtectionEvents.Count
        foreach ($path in $script:hermesManagedFileLinks) {
            $script:hermesProtection[$path] | Should -BeTrue -Because "$path is protected after the first activation"
        }

        { Sync-HermesConfig -Enabled:$true -User 'testuser' -RepoRoot $script:repoRoot > $null } | Should -Not -Throw
        $secondEvents = @()
        for ($i = $firstEventCount; $i -lt $script:hermesProtectionEvents.Count; $i++) {
            $secondEvents += $script:hermesProtectionEvents[$i]
        }
        # WHY: protection is restored right after Deploy-UserWritableSymlink,
        # so that event marks redeployment for each link.
        foreach ($path in $script:hermesManagedFileLinks) {
            $removeAt = [array]::IndexOf($secondEvents, "remove:$path")
            $setAt = [array]::IndexOf($secondEvents, "set:$path")
            $removeAt | Should -BeGreaterThan -1 -Because "$path must be unprotected on the second activation"
            $setAt | Should -BeGreaterThan $removeAt -Because "$path must be unprotected before it is redeployed"
            (Get-Item -LiteralPath $path -Force).LinkType | Should -Be 'SymbolicLink'
        }
    }

    It 'removes stale gateway autostart when symlink privilege is denied' {
        Mock Test-HermesSymlinkPrivilege { return $false }
        # WHY: the global mock reports no hermes CLI, so the no-Run assertion
        # would pass even with the privilege guard removed.
        Mock Get-HermesCliPath { return $script:standInHermes }

        # WHY: a fresh HOME proves the guard runs before the ~/.hermes symlink
        # is attempted; an earlier case can leave that symlink behind.
        $deniedHome = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-hermesdenied-" + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $deniedHome -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $previousHome = $HOME
        Set-Variable -Name HOME -Value $deniedHome -Force
        $warnings = @()
        $deniedHomeSymlinkCreated = $false
        try {
            Sync-HermesConfig -Enabled:$true -User 'testuser' -RepoRoot $script:repoRoot -WarningVariable warnings > $null
            $deniedHomeSymlinkCreated = Test-Path -LiteralPath (Join-Path $deniedHome '.hermes')
        } finally {
            Set-Variable -Name HOME -Value $previousHome -Force
            Clear-HermesTestPath -Path $deniedHome
        }

        ($warnings -join ' ') | Should -Match 'cannot create the Hermes profile links'
        $script:scmRemovals | Should -Be 1
        $script:runValueRemovals.Count | Should -Be 1
        $script:runValueRemovals[0] | Should -Be 'nucleus-hermes-gateway'
        $script:runValues.Count | Should -Be 0
        $deniedHomeSymlinkCreated | Should -BeFalse
    }

    It 'deploys the overlay-owned Hermes files and skill links before writing the gateway Run value' {
        Mock Get-HermesCliPath { return $script:standInHermes }
        Sync-HermesConfig -Enabled:$true -User 'testuser' -RepoRoot $script:repoRoot > $null

        $layout = $script:runTimeHermesLayout
        $layout | Should -Not -BeNullOrEmpty
        foreach ($path in $script:hermesLinkPaths) {
            $layout.Links.ContainsKey($path) | Should -BeTrue -Because "expected a link at $path when the Run value was written"
        }
        $layout.Links[$script:hermesCliSkillsPath].LinkType | Should -Be 'SymbolicLink'
        $layout.Links[$script:hermesCliSkillsPath].Target | Should -Be $script:hermesSkillsOverlay
        foreach ($linkPath in $script:hermesGatewaySkillSources.Keys) {
            $layout.Links[$linkPath].Target | Should -Be $script:hermesGatewaySkillSources[$linkPath]
        }
    }

    It 'links the live repository through HERMES_HOME before writing the gateway Run value' {
        Mock Get-HermesCliPath { return $script:standInHermes }
        Sync-HermesConfig -Enabled:$true -User 'testuser' -RepoRoot $script:repoRoot > $null

        $layout = $script:runTimeHermesLayout
        $layout | Should -Not -BeNullOrEmpty
        $layout.Links.ContainsKey($script:hermesRepoLink) | Should -BeTrue -Because 'the gateway resolves the live checkout through HERMES_HOME/repo'
        $layout.Links[$script:hermesRepoLink].LinkType | Should -Be 'SymbolicLink'
        $layout.Links[$script:hermesRepoLink].Target | Should -Be $script:repoRoot
    }

    It 'renders both Hermes .env files from the user secret catalog before the gateway Run value' {
        Mock Get-HermesCliPath { return $script:standInHermes }
        Sync-HermesConfig -Enabled:$true -User 'testuser' -RepoRoot $script:repoRoot > $null

        $layout = $script:runTimeHermesLayout
        $layout | Should -Not -BeNullOrEmpty
        $script:hermesDecryptCalls | Should -Be "$script:repoRoot|testuser"
        $expected = ($script:hermesExpectedEnvLines -join '|')
        foreach ($path in $script:hermesEnvPaths) {
            $layout.EnvFiles.ContainsKey($path) | Should -BeTrue -Because "expected $path when the Run value was written"
            (($layout.EnvFiles[$path] -split "`n") -join '|') | Should -Be $expected
            $layout.EnvFiles[$path] | Should -Not -Match 'SYSTEM_PROBE|UNRELATED_PROBE'
        }
    }

    It 'installs the pinned Playwright Chromium with bun and leaves the env var alone when none appears' {
        # A stand-in bun that installs nothing is the interesting case: the code
        # chose the version itself, so a cache that stays empty must not be
        # advertised to hermes as holding browsers.
        $emptyHome = Join-Path $script:homeRoot ('empty-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $emptyHome -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $bunRecorder = Save-BunRecorder
        Mock Get-HermesBunPath { return $bunRecorder }
        $envWrites = @()
        Mock Write-HermesUserEnvVar { $envWrites += $Name }

        $previousHome = $HOME
        Set-Variable -Name HOME -Value $emptyHome -Force
        try {
            $warnings = @()
            Sync-HermesConfig -Enabled:$true -User 'testuser' -RepoRoot $script:repoRoot -WarningVariable warnings > $null
        } finally {
            Set-Variable -Name HOME -Value $previousHome -Force
        }

        # The version has to come from the lockfile pin, not from whatever the
        # registry serves, and bun replaces npx per package-installation-scope.
        (Get-Content -Raw -LiteralPath $script:BunRecordPath) | Should -Match 'playwright@1\.63\.0'
        (Get-Content -Raw -LiteralPath $script:BunRecordPath) | Should -Match 'install chromium'
        ($warnings -join ' ') | Should -Match 'leaving PLAYWRIGHT_BROWSERS_PATH unchanged'
        $envWrites | Should -Not -Contain 'PLAYWRIGHT_BROWSERS_PATH'
    }
}
