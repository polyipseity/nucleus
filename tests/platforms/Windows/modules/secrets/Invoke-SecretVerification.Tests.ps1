<#
.SYNOPSIS
    Pester tests for the Windows managed SSH private key validity probe.

.DESCRIPTION
    Test-ManagedSshPrivateKey decides whether a managed SSH private key is acceptable
    on Windows.  Before this check existed, Invoke-SecretVerification asserted only that
    each managed key file existed and was non-empty, so a malformed key passed on
    Windows while the POSIX verifier
    (src/scripts/secrets/verify-secret-decryption.sh) rejected it.  The two hosts
    disagreed about whether the same managed state was acceptable.

    The probe is two checks.  The file's first line must carry an OpenSSH private key
    PEM header, and `ssh-keygen -l -f` must report a fingerprint.  -l reads the
    cleartext public-key blob out of the openssh-key-v1 container, so it succeeds
    whether or not the key carries a passphrase; a passphrase-protected managed key
    is valid.  The header check is what -l cannot do: on its own -l also accepts a
    bare .pub public key file, which is why the public-key case below must be rejected.

    EXECUTION STATUS -- read before trusting a green result.
    Authored on macOS, where this session has no Windows host.  The cases were
    executed against the real OpenSSH ssh-keygen on macOS and passed.  That covers the
    probe's KEY SEMANTICS, which do not depend on the host OS: which keys are
    accepted, which are rejected, and that a failure names the offending file.  It
    does NOT cover ARGUMENT PASSING, which is PowerShell-edition-dependent and is
    the part a Windows host has to prove.  None of these cases has been executed on
    Windows, where the following remain unverified:
      - that the Arguments string's quoted path survives Windows PowerShell 5.1's
        native binder as one argument (the reason the probe uses Process with an
        Arguments string instead of passing a PowerShell value);
      - that Get-Content -TotalCount 1 reads the header the same way under 5.1;
      - that a missing key file is rejected by name rather than by a hung ssh-keygen;
      - the apply.ps1 wiring that resolves ssh-keygen and passes -SshKeygenExe;
      - Resolve-Executable against the Windows candidate paths;
      - the step-1 managed-ssh-key-paths enumeration in Invoke-SecretVerification.
    To close that gap on a Windows host:
      Invoke-Pester -Path tests\platforms\Windows\modules\secrets\Invoke-SecretVerification.Tests.ps1

    These cases deliberately do NOT use a skip-guard.  The Pester step reports only
    TotalCount and FailedCount, so a skipped case would pass CI while asserting nothing;
    a host without ssh-keygen must fail loudly instead.

.NOTES
    Requires: ssh-keygen resolvable via the same candidate list apply.ps1 uses
              (%SystemRoot%\System32\OpenSSH\ssh-keygen.exe, Git for Windows'
              usr\bin\ssh-keygen.exe, or PATH; /usr/bin/ssh-keygen on macOS).
    Exit codes: 0 on success; 1 on failure
#>

BeforeAll {
    $ErrorActionPreference = 'Stop'
    $WarningPreference = 'SilentlyContinue'

    # tests/platforms/Windows/modules/secrets -> five levels up is the repo root.
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../..' | Join-Path -ChildPath '..')).Path
    . (Join-Path $script:repoRoot 'src/platforms/Windows/modules/Resolve-Executable.ps1')
    . (Join-Path $script:repoRoot 'src/platforms/Windows/modules/secrets/Invoke-SecretVerification.ps1')

    # Candidate list mirrors apply.ps1 so this suite can never red where nucleus-apply
    # works, plus the two macOS locations so the cases are executable here.  A superset
    # is the safe direction: production resolution can only ever be stricter than this,
    # so a host that provisions successfully cannot fail the suite on resolution alone.
    $candidates = @('/usr/bin/ssh-keygen', '/opt/homebrew/bin/ssh-keygen')
    if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        $candidates += (Join-Path -Path $env:SystemRoot -ChildPath 'System32\OpenSSH\ssh-keygen.exe')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $candidates += (Join-Path -Path $env:ProgramFiles -ChildPath 'Git\usr\bin\ssh-keygen.exe')
    }
    $onPath = Get-Command -Name 'ssh-keygen' -CommandType Application -ErrorAction Ignore |
        Select-Object -First 1 -ExpandProperty Source
    if ($onPath) {
        $candidates += $onPath
    }
    # Resolve-Executable throws when nothing resolves, which is the intended loud
    # failure: the Pester step ignores SkippedCount, so skipping would report success.
    $script:sshKeygen = Resolve-Executable -Name 'ssh-keygen' -CandidatePaths $candidates

    # Key generation goes through Process for the same reason the probe under test does.
    # `& ssh-keygen -N ''` as a PowerShell value can be dropped by a 5.1 native binder,
    # and a dropped -N makes ssh-keygen PROMPT for a new key's passphrase, hanging the
    # suite on the very host these cases are meant to reach.  Encoding the passphrase
    # inside an Arguments string sidesteps the binder entirely.
    function Initialize-TestSshKey {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Path,

            # A switch, not a passphrase parameter: the two fixtures needed are an
            # unprotected key and one protected by a fixed test constant, so no caller
            # ever has to pass a secret in.  Naming the verb Initialize rather than New
            # keeps this an honest description of fixture setup instead of adding
            # ShouldProcess ceremony to a test helper that has no WhatIf caller.
            [switch]$Protected
        )
        $encodedPassphrase = if ($Protected) { '"nucleus-test-passphrase"' } else { '""' }
        $keygenArguments = '-q -t ed25519 -N ' + $encodedPassphrase + ' -C "nucleus-test" -f "' + $Path + '"'
        $keygenInfo = New-Object System.Diagnostics.ProcessStartInfo
        $keygenInfo.FileName = $script:sshKeygen
        $keygenInfo.Arguments = $keygenArguments
        $keygenInfo.UseShellExecute = $false
        $keygenInfo.RedirectStandardInput = $true
        $keygenInfo.RedirectStandardOutput = $true
        $keygenInfo.RedirectStandardError = $true
        $keygen = [System.Diagnostics.Process]::Start($keygenInfo)
        $keygen.StandardInput.Close()
        $keygenError = $keygen.StandardError.ReadToEndAsync()
        if (-not $keygen.WaitForExit(30000)) {
            $keygen.Kill()
            throw "test setup: ssh-keygen did not exit within 30 s while creating '$Path'."
        }
        $keygen.WaitForExit()
        if ($keygen.ExitCode -ne 0) {
            throw "test setup: ssh-keygen could not create '$Path': $($keygenError.Result.Trim())"
        }
    }

    # Three real keys, because the distinction under test is a property of the key
    # file that only ssh-keygen can judge: a fixture stub could not tell them apart.
    $script:KeyRoot = Join-Path ([IO.Path]::GetTempPath()) ("secret-verification-$([guid]::NewGuid())")
    New-Item -ItemType Directory -Path $script:KeyRoot -Force > $null
    $script:PlainKey = Join-Path $script:KeyRoot 'ssh_personal_plain'
    $script:LockedKey = Join-Path $script:KeyRoot 'ssh_personal_locked'
    Initialize-TestSshKey -Path $script:PlainKey
    Initialize-TestSshKey -Path $script:LockedKey -Protected

    # The public-key fixture is the one case a hand-written file could stand in for,
    # but deriving it keeps it honest: it is a real .pub that ssh-keygen -l accepts,
    # so a pass can only come from the header check rejecting it.
    $script:PublicKey = Join-Path $script:KeyRoot 'ssh_personal_plain.pub'
    $deriveInfo = New-Object System.Diagnostics.ProcessStartInfo
    $deriveInfo.FileName = $script:sshKeygen
    $deriveInfo.Arguments = '-y -f "' + $script:PlainKey + '"'
    $deriveInfo.UseShellExecute = $false
    $deriveInfo.RedirectStandardInput = $true
    $deriveInfo.RedirectStandardOutput = $true
    $deriveInfo.RedirectStandardError = $true
    $derive = [System.Diagnostics.Process]::Start($deriveInfo)
    $derive.StandardInput.Close()
    $deriveOut = $derive.StandardOutput.ReadToEndAsync()
    $deriveError = $derive.StandardError.ReadToEndAsync()
    if (-not $derive.WaitForExit(30000)) {
        $derive.Kill()
        throw "test setup: ssh-keygen did not exit within 30 s while deriving the public key fixture."
    }
    $derive.WaitForExit()
    if ($derive.ExitCode -ne 0) {
        throw "test setup: ssh-keygen could not derive a public key fixture: $($deriveError.Result.Trim())"
    }
    Set-Content -LiteralPath $script:PublicKey -Value $deriveOut.Result -NoNewline

    # A file that exists, is non-empty, and is not a key at all.  The old
    # existence-only check passed it, which is why the probe exists.
    $script:GarbageKey = Join-Path $script:KeyRoot 'ssh_personal_garbage'
    Set-Content -LiteralPath $script:GarbageKey -Value 'this is not a private key' -NoNewline

    # A path that was never created.  Proves the probe rejects a missing file by name
    # rather than handing ssh-keygen a path that does not resolve.
    $script:MissingKey = Join-Path $script:KeyRoot 'ssh_personal_absent'

    # The shadowing regression. materialize writes <key>.pub beside <key>, and
    # ssh-keygen -l -f <key> prefers that sibling, reporting ITS fingerprint without
    # opening the private key.  A broken private key next to a valid .pub therefore
    # looks fine unless the probe goes through a sibling-free path.  Built by cutting
    # a real key short, because a literal PEM block would trip the private-key
    # detector in prek.
    $script:ShadowedKey = Join-Path $script:KeyRoot 'ssh_personal_shadowed'
    $keyLines = Get-Content -LiteralPath $script:PlainKey
    # Keep the header and a partial first base64 line: that line carries the whole
    # public blob, so it has to be cut mid-line for the file to stop parsing.
    # Newline separated, not -NoNewline, which would run the two together and make
    # the header check reject it for the wrong reason.
    $truncatedBody = $keyLines[0] + [Environment]::NewLine + $keyLines[1].Substring(0, 40) + [Environment]::NewLine
    Set-Content -LiteralPath $script:ShadowedKey -Value $truncatedBody -NoNewline
    Copy-Item -LiteralPath $script:PublicKey -Destination "$script:ShadowedKey.pub" -Force
}

AfterAll {
    if ($script:KeyRoot -and (Test-Path -LiteralPath $script:KeyRoot)) {
        Remove-Item -LiteralPath $script:KeyRoot -Recurse -Force -ErrorAction Ignore
    }
}

Describe 'Test-ManagedSshPrivateKey' {
    Context 'probe prerequisites' {
        It 'resolves an ssh-keygen executable to probe keys with' {
            # Pending Windows host execution: resolution against the Windows candidate
            # paths.  Only the macOS locations have been exercised so far.
            # No skip-guard: the Pester step ignores SkippedCount, so skipping here would
            # report success while asserting nothing.
            Test-Path -LiteralPath $script:sshKeygen |
                Should -BeTrue -Because 'ssh-keygen is required to probe a managed private key and must not be silently skipped'
        }
    }

    Context 'unencrypted key' {
        It 'accepts a managed private key that carries no passphrase' {
            # Pending Windows host execution: this proves the key semantics, not that
            # the quoted path in the Arguments string survives the 5.1 native binder.
            { Test-ManagedSshPrivateKey -SshKeygenExe $script:sshKeygen -PrivateKeyPath $script:PlainKey } |
                Should -Not -Throw
        }
    }

    Context 'passphrase-protected key' {
        It 'accepts a passphrase-protected key, which is a valid private key' {
            # The contract this guards: a protected key is valid, and -l reads the
            # cleartext public-key blob without ever needing the passphrase.  The
            # previous -y -P "" probe rejected it, which made a correctly managed
            # key a hard activation failure.
            { Test-ManagedSshPrivateKey -SshKeygenExe $script:sshKeygen -PrivateKeyPath $script:LockedKey } |
                Should -Not -Throw
        }
    }

    Context 'public key file' {
        It 'rejects a bare public key file, which ssh-keygen -l alone would accept' {
            # The gap the header check closes.  -l reports a fingerprint for this file
            # just as readily as for a private key, so without the header check this
            # case would pass and a public key could be materialised in place of the
            # private one it stands in for.
            # Pending Windows host execution: proves the rejection, not that
            # Get-Content -TotalCount 1 reads the same header under 5.1.
            $threw = $null
            try {
                Test-ManagedSshPrivateKey -SshKeygenExe $script:sshKeygen -PrivateKeyPath $script:PublicKey
            }
            catch {
                $threw = $_.Exception.Message
            }
            $threw | Should -Not -BeNullOrEmpty
            # Attribution: the message must name this file, so a failure among several
            # enumerated managed keys is diagnosable.
            $threw | Should -BeLike "*$(Split-Path -Path $script:PublicKey -Leaf)*"
        }
    }

    Context 'public key shadowing the private key' {
        It 'rejects a broken private key even when a valid .pub sits beside it' {
            # The regression that makes the sibling-free probe necessary. Probing the
            # managed path directly lets ssh-keygen -l read <key>.pub instead, so a
            # corrupt private key would pass. Without this case the symlink in the
            # probe could be dropped and the check would silently stop working.
            $threw = $null
            try {
                Test-ManagedSshPrivateKey -SshKeygenExe $script:sshKeygen -PrivateKeyPath $script:ShadowedKey
            }
            catch {
                $threw = $_.Exception.Message
            }
            $threw | Should -Not -BeNullOrEmpty
            $threw | Should -BeLike "*$(Split-Path -Path $script:ShadowedKey -Leaf)*"
        }
    }

    Context 'unparsable key' {
        It 'rejects a file that is not a key and names the offending file' {
            # Existence is not validity: this file exists and is non-empty, so the
            # check that preceded the probe accepted it.
            $threw = $null
            try {
                Test-ManagedSshPrivateKey -SshKeygenExe $script:sshKeygen -PrivateKeyPath $script:GarbageKey
            }
            catch {
                $threw = $_.Exception.Message
            }
            $threw | Should -Not -BeNullOrEmpty
            $threw | Should -BeLike "*$(Split-Path -Path $script:GarbageKey -Leaf)*"
        }

        It 'rejects a managed key path that does not exist' {
            # Rejected before ssh-keygen runs, so a stale manifest entry fails by name
            # rather than surfacing as an empty fingerprint.
            $threw = $null
            try {
                Test-ManagedSshPrivateKey -SshKeygenExe $script:sshKeygen -PrivateKeyPath $script:MissingKey
            }
            catch {
                $threw = $_.Exception.Message
            }
            $threw | Should -Not -BeNullOrEmpty
            $threw | Should -BeLike "*$(Split-Path -Path $script:MissingKey -Leaf)*"
        }
    }
}
