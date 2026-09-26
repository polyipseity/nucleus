<#
.SYNOPSIS
    Pester tests for the Windows managed SSH private key passphrase probe.

.DESCRIPTION
    Test-ManagedSshPrivateKey decides whether a managed SSH private key is acceptable
    on Windows.  Before this check existed, Invoke-SecretVerification asserted only that
    each managed key file existed and was non-empty, so Windows accepted a
    passphrase-protected key that the POSIX verifier
    (src/scripts/secrets/verify-secret-decryption.sh) rejects.  The two hosts disagreed
    about whether the same managed state was acceptable.

    The probe runs `ssh-keygen -y -P ""`, which derives from the PRIVATE key and
    supplies an empty passphrase.  A passphrase-protected key is therefore rejected
    because the supplied passphrase is wrong -- not because the file is missing.  The
    same reasoning is why -e is not used: it reads the unencrypted openssh-key-v1
    header, which a protected key still has.

    EXECUTION STATUS -- read before trusting a green result.
    Authored on macOS, where this session has no Windows host.  All 3 cases were
    executed against the real OpenSSH ssh-keygen on macOS and passed (3 passed,
    0 failed, 0 skipped).  That covers the probe's KEY SEMANTICS, which do not depend
    on the host OS: which keys are accepted, and the failure names the offending file.
    It does NOT cover ARGUMENT PASSING, which is PowerShell-edition-dependent and is
    the part a Windows host has to prove.  None of these cases has been executed on
    Windows, where the following remain unverified:
      - that the `-P ""` empty-argv encoding in the Arguments string survives Windows
        PowerShell 5.1's native binder as a single empty argument rather than being
        dropped or collapsed (the reason the probe uses Process + an Arguments string
        instead of a PowerShell value);
      - that a passphrase prompt really takes EOF and exits non-zero rather than
        blocking, i.e. the stdin-close and bounded-wait guard actually prevents a
        stalled apply on that host;
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

    # Two real keys, because the distinction under test is a property of the key file
    # that only ssh-keygen can judge: a fixture stub could not tell them apart.
    $script:KeyRoot = Join-Path ([IO.Path]::GetTempPath()) ("secret-verification-$([guid]::NewGuid())")
    New-Item -ItemType Directory -Path $script:KeyRoot -Force > $null
    $script:PlainKey = Join-Path $script:KeyRoot 'ssh_personal_plain'
    $script:LockedKey = Join-Path $script:KeyRoot 'ssh_personal_locked'
    Initialize-TestSshKey -Path $script:PlainKey
    Initialize-TestSshKey -Path $script:LockedKey -Protected
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
        It 'accepts a managed private key readable with an empty passphrase' {
            # Pending Windows host execution: this proves the key semantics, not that
            # `-P ""` survives the 5.1 native binder.  An unencrypted key is the case a
            # collapsed or over-quoted empty argument would FALSE-REJECT, so a pass here
            # is evidence about argument encoding and a pass under 5.1 is still required.
            { Test-ManagedSshPrivateKey -SshKeygenExe $script:sshKeygen -PrivateKeyPath $script:PlainKey } |
                Should -Not -Throw
        }
    }

    Context 'passphrase-protected key' {
        It 'rejects a passphrase-protected key and names the offending file' {
            # Pending Windows host execution: this proves the rejection and the
            # attribution, not that a prompt takes EOF instead of blocking on that host.
            # The defect: an existence-only check passes this key, so Windows accepts a
            # state the POSIX host rejects.
            $threw = $null
            try {
                Test-ManagedSshPrivateKey -SshKeygenExe $script:sshKeygen -PrivateKeyPath $script:LockedKey
            }
            catch {
                $threw = $_.Exception.Message
            }
            $threw | Should -Not -BeNullOrEmpty
            # Attribution: the message must name this key, so a failure among several
            # enumerated managed keys is diagnosable.
            $threw | Should -BeLike "*$(Split-Path -Path $script:LockedKey -Leaf)*"
        }
    }
}
