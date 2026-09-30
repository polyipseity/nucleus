<#
.SYNOPSIS
    Pester coverage for the Windows whisper model convergence module.
.DESCRIPTION
    Drives Sync-WhisperModel against a fixture repository and a fixture USER
    root, covering the convergence decisions: a model already matching its pin
    is left alone, a model whose digest drifted is re-fetched rather than
    trusted, a pin with nothing deployed fails loudly, disable removes only the
    managed files, and the lockfile shape is validated before anything is
    fetched.

    The download path is exercised through a connection-refused URL on port 1.
    That fails immediately instead of waiting out a real download, so the suite
    stays offline and fast while still proving the module attempts a fetch and
    surfaces the failure rather than swallowing it.
.NOTES
    Environment variables: %LOCALAPPDATA% and %USERPROFILE% are overridden at
    script scope so the suite never reads or writes real machine state.
    Exit codes: 0 on success; 1 on failure
#>

Describe 'Sync-WhisperModel' {
    BeforeAll {
        $script:moduleRoot = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\src\platforms\Windows\modules'
        Import-Module (Join-Path -Path $script:moduleRoot -ChildPath 'Format-NucleusOutput.psm1') -Force
        . (Join-Path -Path $script:moduleRoot -ChildPath 'ManagedPaths.ps1')
        # The module dot-sources this inside its own body, so the tests could not
        # rely on it being defined in their scope; the byte-level assertions call
        # Get-NucleusSriHash directly and need it here.
        . (Join-Path -Path $script:moduleRoot -ChildPath 'lib\PsGalleryPin.ps1')
        . (Join-Path -Path $script:moduleRoot -ChildPath 'user\Sync-WhisperModel.ps1')

        $script:tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('nucleus-whisper-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:tempRoot -Force # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup

        $script:originalLocalAppData = $env:LOCALAPPDATA
        $script:originalUserProfile = $env:USERPROFILE
        $env:LOCALAPPDATA = Join-Path $script:tempRoot 'localappdata'
        $env:USERPROFILE = $script:tempRoot
        $script:modelDir = Join-Path (Get-NucleusUserRoot) 'models'

        # The SRI of the three bytes 'abc'. Fixtures are built from those exact
        # bytes so the pinned digest and the digest the module computes are both
        # known without hashing anything by hand in the assertion.
        $script:SriAbc = 'sha256-ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0='
        $script:SriTampered = 'sha256-ESnm8ZXZfp7DjGJR2l5EmlK7E2n6CAHncAIQZje/kLc='
        $script:Rev = '5359861c739e955e79d9a303bcbc70fb988958b1'
        # Port 1 on loopback refuses at once: the fetch is attempted and fails
        # without leaving the machine or waiting out a real transfer.
        $script:UnreachableUrl = 'https://127.0.0.1:1/ggml-fixture.bin'

        function Get-WhisperFixtureRepo {
            param([hashtable]$WhisperSection)

            $repo = Join-Path $script:tempRoot ('repo-' + [guid]::NewGuid().ToString('N'))
            $lockDir = Join-Path $repo 'src\lockfiles'
            $null = New-Item -ItemType Directory -Path $lockDir -Force
            if ($WhisperSection) {
                $lock = @{ whisper = $WhisperSection }
            }
            else {
                $lock = @{ scoop = @{} }
            }
            ($lock | ConvertTo-Json -Depth 6) | Set-Content -Path (Join-Path $lockDir 'lockfile.json')
            return $repo
        }

        function Get-WhisperPin {
            param(
                [string]$Hash = $script:SriAbc,
                [string]$Url = $script:UnreachableUrl
            )
            return @{ hash = $Hash; url = $Url; revision = $script:Rev }
        }

        function Write-FixtureModel {
            param([string]$Name, [byte[]]$Bytes)
            $null = New-Item -ItemType Directory -Path $script:modelDir -Force
            [System.IO.File]::WriteAllBytes((Join-Path $script:modelDir $Name), $Bytes)
        }

        function Clear-ModelFixture {
            if (Test-Path -LiteralPath $script:modelDir) {
                # check-suppress:suppression_doc: cleanup in test setup -- an already-absent directory is not an error.
                Remove-Item -LiteralPath $script:modelDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # Run the module and capture its info stream. Write-NucleusInfo writes to
        # the success stream, so the returned array is the module's narration.
        function Invoke-Sync {
            param([string]$RepoRoot, [bool]$Enabled = $true)
            return @(Sync-WhisperModel -RepoRoot $RepoRoot -Enabled:$Enabled)
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

    BeforeEach {
        Clear-ModelFixture
    }

    Context 'when the deployed model already matches the pin' {
        It 'skips the download and reports the match' {
            Write-FixtureModel -Name 'ggml-fixture.bin' -Bytes ([byte[]](0x61, 0x62, 0x63))
            $repo = Get-WhisperFixtureRepo -WhisperSection @{ 'ggml-fixture.bin' = Get-WhisperPin }

            $messages = Invoke-Sync -RepoRoot $repo
            $text = $messages -join "`n"

            $text | Should -Match 'already matches the pin' -Because "narration was: $text"
            @($messages | Where-Object { $_ -Match 'downloading' }).Count |
                Should -Be 0 -Because "a matching model must not be fetched again; narration was: $text"
        }

        It 'is idempotent across repeated runs' {
            Write-FixtureModel -Name 'ggml-fixture.bin' -Bytes ([byte[]](0x61, 0x62, 0x63))
            $repo = Get-WhisperFixtureRepo -WhisperSection @{ 'ggml-fixture.bin' = Get-WhisperPin }

            $first = Invoke-Sync -RepoRoot $repo
            $second = Invoke-Sync -RepoRoot $repo
            $text = $second -join "`n"

            ($first -join "`n") | Should -Match 'already matches the pin'
            $text | Should -Match 'already matches the pin' -Because "the second run must converge, not refetch; narration was: $text"
            @($second | Where-Object { $_ -Match 'downloading' }).Count | Should -Be 0
        }

        It 'leaves the model bytes untouched' {
            Write-FixtureModel -Name 'ggml-fixture.bin' -Bytes ([byte[]](0x61, 0x62, 0x63))
            $repo = Get-WhisperFixtureRepo -WhisperSection @{ 'ggml-fixture.bin' = Get-WhisperPin }

            $null = Invoke-Sync -RepoRoot $repo
            (Get-NucleusSriHash -Path (Join-Path $script:modelDir 'ggml-fixture.bin')) | Should -Be $script:SriAbc
        }
    }

    Context 'when the deployed model has drifted' {
        It 'reports the digest it found and attempts a re-download, then fails loudly' {
            Write-FixtureModel -Name 'ggml-fixture.bin' -Bytes ([byte[]](0x74, 0x61, 0x6d))
            $repo = Get-WhisperFixtureRepo -WhisperSection @{ 'ggml-fixture.bin' = Get-WhisperPin }

            $ErrorActionPreference = 'Continue'
            $messages = @(Sync-WhisperModel -RepoRoot $repo -Enabled:$true 2>&1)
            $text = $messages -join "`n"

            $text | Should -Match 'does not match the pin' -Because "the drift must be announced; output was: $text"
            $text | Should -Match ([regex]::Escape($script:SriTampered)) -Because "the deployed digest must be reported; output was: $text"
            $text | Should -Match 'downloading' -Because "a drifted model must be re-fetched; output was: $text"
            # Both digests, wanted first, so the operator can tell a truncated
            # file from a stale pin without re-hashing the lockfile by hand.
            # This is the same wording contract as the POSIX _lfe_check_whisper
            # probe, which reports "expected <hex>, found <hex>". The escaped
            # digests in one pattern pin the ORDER too, which is the part that
            # actually tells the two values apart on screen. Plain {0}/{1} are
            # the format placeholders: \{0\} would be a .NET literal-brace escape
            # and -f would substitute nothing. Neither digest contains a brace,
            # so no escaping is needed around the placeholders.
            $bothDigests = 'expected {0}.*found {1}' -f [regex]::Escape($script:SriAbc), [regex]::Escape($script:SriTampered)
            $text | Should -Match $bothDigests -Because "the pinned digest must precede the deployed one; output was: $text"
        }

        It 'does not overwrite the drifted file with an unverified download' {
            Write-FixtureModel -Name 'ggml-fixture.bin' -Bytes ([byte[]](0x74, 0x61, 0x6d))
            $repo = Get-WhisperFixtureRepo -WhisperSection @{ 'ggml-fixture.bin' = Get-WhisperPin }

            # The fetch is expected to fail; what matters is that the bad file is
            # still there afterwards, because the module only moves a temp file
            # into place after its digest verifies. Recording the failure also
            # turns the expected throw into a real assertion rather than a
            # swallowed one.
            $ErrorActionPreference = 'Continue'
            $fetchFailure = $null
            try { $null = Sync-WhisperModel -RepoRoot $repo -Enabled:$true }
            catch { $fetchFailure = $_.Exception }
            $fetchFailure | Should -Not -BeNullOrEmpty -Because 'the fixture url refuses the connection on port 1'
            (Get-NucleusSriHash -Path (Join-Path $script:modelDir 'ggml-fixture.bin')) |
                Should -Be $script:SriTampered -Because 'a failed download must not replace the deployed file'
        }
    }

    Context 'when a pinned model was never deployed' {
        It 'throws instead of passing quietly' {
            $repo = Get-WhisperFixtureRepo -WhisperSection @{ 'ggml-absent.bin' = Get-WhisperPin }

            $ErrorActionPreference = 'Continue'
            { Sync-WhisperModel -RepoRoot $repo -Enabled:$true } | Should -Throw
        }

        It 'announces the download it is about to attempt' {
            $repo = Get-WhisperFixtureRepo -WhisperSection @{ 'ggml-absent.bin' = Get-WhisperPin }

            $ErrorActionPreference = 'Continue'
            $messages = @(Sync-WhisperModel -RepoRoot $repo -Enabled:$true 2>&1)
            ($messages -join "`n") | Should -Match 'downloading'
        }
    }

    Context 'when disabled' {
        It 'removes only the pinned model and leaves the rest of the models directory' {
            Write-FixtureModel -Name 'ggml-fixture.bin' -Bytes ([byte[]](0x61, 0x62, 0x63))
            Write-FixtureModel -Name 'unrelated.bin' -Bytes ([byte[]](0x21))
            $repo = Get-WhisperFixtureRepo -WhisperSection @{ 'ggml-fixture.bin' = Get-WhisperPin }

            $null = Invoke-Sync -RepoRoot $repo -Enabled $false

            (Test-Path -LiteralPath (Join-Path $script:modelDir 'ggml-fixture.bin')) |
                Should -BeFalse -Because 'the pinned model is managed state and must go'
            (Test-Path -LiteralPath (Join-Path $script:modelDir 'unrelated.bin')) |
                Should -BeTrue -Because 'an unlisted file is not ours to delete'
            (Test-Path -LiteralPath $script:modelDir -PathType Container) |
                Should -BeTrue -Because 'the models directory is not ours to delete'
        }

        It 'reports what it removed' {
            Write-FixtureModel -Name 'ggml-fixture.bin' -Bytes ([byte[]](0x61, 0x62, 0x63))
            $repo = Get-WhisperFixtureRepo -WhisperSection @{ 'ggml-fixture.bin' = Get-WhisperPin }

            $messages = Invoke-Sync -RepoRoot $repo -Enabled $false
            ($messages -join "`n") | Should -Match 'removed ggml-fixture\.bin'
        }

        It 'is a no-op when nothing is deployed' {
            $repo = Get-WhisperFixtureRepo -WhisperSection @{ 'ggml-absent.bin' = Get-WhisperPin }

            { $null = Invoke-Sync -RepoRoot $repo -Enabled $false } | Should -Not -Throw
        }
    }

    Context 'when the lockfile is unusable' {
        It 'throws when there is no whisper section' {
            $repo = Get-WhisperFixtureRepo -WhisperSection $null

            $ErrorActionPreference = 'Stop'
            { Sync-WhisperModel -RepoRoot $repo -Enabled:$true } |
                Should -Throw -ExpectedMessage '*no whisper section*'
        }

        It 'throws when the lockfile file is missing' {
            $missing = Join-Path $script:tempRoot ('absent-' + [guid]::NewGuid().ToString('N'))

            $ErrorActionPreference = 'Stop'
            { Sync-WhisperModel -RepoRoot $missing -Enabled:$true } |
                Should -Throw -ExpectedMessage '*lockfile not found*'
        }

        It 'throws when an entry is missing its hash' {
            $repo = Get-WhisperFixtureRepo -WhisperSection @{ 'ggml-fixture.bin' = @{ url = $script:UnreachableUrl; revision = $script:Rev } }

            $ErrorActionPreference = 'Stop'
            { Sync-WhisperModel -RepoRoot $repo -Enabled:$true } |
                Should -Throw -ExpectedMessage '*must declare both url and hash*'
        }

        It 'throws when an entry is missing its url' {
            $repo = Get-WhisperFixtureRepo -WhisperSection @{ 'ggml-fixture.bin' = @{ hash = $script:SriAbc; revision = $script:Rev } }

            $ErrorActionPreference = 'Stop'
            { Sync-WhisperModel -RepoRoot $repo -Enabled:$true } |
                Should -Throw -ExpectedMessage '*must declare both url and hash*'
        }

        It 'validates the pin before fetching anything' {
            $repo = Get-WhisperFixtureRepo -WhisperSection @{ 'ggml-fixture.bin' = @{ url = $script:UnreachableUrl; revision = $script:Rev } }

            $ErrorActionPreference = 'Continue'
            $messages = @(Sync-WhisperModel -RepoRoot $repo -Enabled:$true 2>&1)
            @($messages | Where-Object { $_ -Match 'downloading' }).Count |
                Should -Be 0 -Because 'a malformed pin must be rejected before any network call'
        }
    }
}
