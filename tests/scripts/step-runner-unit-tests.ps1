#Requires -Version 7.4
# Unit tests for step-runner.ps1 functions in isolation (PowerShell).
# Covers registration arity and token validation, the applicability matrix, and
# --only-steps.

[CmdletBinding()]
param()

$script:passCount = 0
$script:failCount = 0
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$stepRunner = Join-Path $repoRoot 'src\scripts\lib\step-runner.ps1'

function Assert-Pass {
    param([string]$Name)
    Write-Output "✓ $Name"
    $script:passCount++
}

function Assert-Fail {
    param([string]$Name, [string]$Reason)
    Write-Output "FAIL $Name : $Reason"
    $script:failCount++
}

# ---- Spec A: Step ID registration (-Id form) ----

function Test-RegisterStep-WithId {
    Initialize-StepState
    . $stepRunner

    Register-Step -Id "code-formatting" -Number 1 -Name "Code formatting" -Action { $true }

    if ($script:StepIds -and $script:StepIds[0] -eq "code-formatting" -and $script:StepNumbers[0] -eq 1) {
        Assert-Pass "Register-Step -Id stores id, number, name correctly"
    } else {
        $ids = if ($script:StepIds) { $script:StepIds[0] } else { "null" }
        Assert-Fail "Register-Step -Id" "Expected id='code-formatting' number=1, got id=$ids number=$($script:StepNumbers[0])"
    }
}

function Test-RegisterStep-MultipleWithId {
    Initialize-StepState
    . $stepRunner

    Register-Step -Id "one" -Number 1 -Name "One" -Action { $true }
    Register-Step -Id "two" -Number 2 -Name "Two" -Action { $true }
    Register-Step -Id "three" -Number 3 -Name "Three" -Action { $true }

    if ($script:StepIds.Count -eq 3 -and $script:StepIds[0] -eq "one" -and $script:StepIds[2] -eq "three") {
        Assert-Pass "Register-Step accumulates multiple steps with IDs"
    } else {
        Assert-Fail "Register-Step multiple IDs" "Expected 3 IDs, got $($script:StepIds.Count)"
    }
}

function Test-RegisterStep-DeclaredToken {
    Initialize-StepState
    . $stepRunner

    Register-Step -Id "declared" -Number 1 -Name "Declared" -Platform posix -Mode full -Requires deployed-host -Action { $true }

    if ($script:StepPlatforms[0] -eq "posix" -and $script:StepModes[0] -eq "full" -and $script:StepRequires[0] -eq "deployed-host") {
        Assert-Pass "Register-Step stores the declared platform, mode and requires tokens"
    } else {
        Assert-Fail "Register-Step declared tokens" "got platform='$($script:StepPlatforms[0])' mode='$($script:StepModes[0])' requires='$($script:StepRequires[0])'"
    }
}

function Test-RegisterStep-UndeclaredDefault {
    Initialize-StepState
    . $stepRunner

    Register-Step -Id "plain" -Number 1 -Name "Plain" -Action { $true }

    if ($script:StepPlatforms[0] -eq "any" -and $script:StepModes[0] -eq "any" -and $script:StepRequires[0] -eq "none") {
        Assert-Pass "Register-Step defaults to any/any/none"
    } else {
        Assert-Fail "Register-Step defaults" "got platform='$($script:StepPlatforms[0])' mode='$($script:StepModes[0])' requires='$($script:StepRequires[0])'"
    }
}

function Test-RegisterStep-UnknownToken {
    $cases = @(
        @{ Name = 'platform'; Arguments = @{ Platform = 'darwin' }; Message = "unknown platform token 'darwin' (expected posix|windows|any)" },
        @{ Name = 'mode'; Arguments = @{ Mode = 'partial' }; Message = "unknown mode token 'partial' (expected any|full|scoped)" },
        @{ Name = 'requires'; Arguments = @{ Requires = 'gpu' }; Message = "unknown requires token 'gpu' (expected none|nix|network|sops-machine-key|deployed-host)" }
    )
    foreach ($case in $cases) {
        Initialize-StepState
        $threw = $false
        $message = ''
        try {
            . $stepRunner
            $parameters = $case.Arguments + @{ Id = 'bad'; Number = 1; Name = 'Bad'; Action = { $true } }
            Register-Step @parameters
        } catch {
            $threw = $true
            $message = $_.Exception.Message
        }
        if ($threw -and $message.Contains($case.Message)) {
            Assert-Pass "Register-Step rejects an unknown $($case.Name) token"
        } else {
            Assert-Fail "Register-Step unknown $($case.Name)" "threw=$threw message='$message'"
        }
    }
}

function Test-RegisterStep-IdWithDigitError {
    Initialize-StepState
    $exitCode = 0
    try {
        . $stepRunner
        Register-Step -Id "test-1-bad" -Number 1 -Name "Bad" -Action { $true }
    } catch {
        $exitCode = 1
    }
    if ($exitCode -eq 1) {
        Assert-Pass "Register-Step with digit in ID errors (Spec A)"
    } else {
        Assert-Fail "Register-Step digit ID" "Expected error for ID containing digit"
    }
}

function Test-RegisterStep-EmptyIdError {
    Initialize-StepState
    $exitCode = 0
    try {
        . $stepRunner
        Register-Step -Id "" -Number 1 -Name "Empty" -Action { $true }
    } catch {
        $exitCode = 1
    }
    if ($exitCode -eq 1) {
        Assert-Pass "Register-Step with empty ID errors (Spec A)"
    } else {
        Assert-Fail "Register-Step empty ID" "Expected error for empty ID"
    }
}

function Test-RegisterStep-DuplicateIdError {
    Initialize-StepState
    $exitCode = 0
    try {
        . $stepRunner
        Register-Step -Id "dup" -Number 1 -Name "First" -Action { $true }
        Register-Step -Id "dup" -Number 2 -Name "Second" -Action { $true }
    } catch {
        $exitCode = 1
    }
    if ($exitCode -eq 1) {
        Assert-Pass "Register-Step duplicate ID errors (Spec A)"
    } else {
        Assert-Fail "Register-Step dup ID" "Expected error for duplicate ID"
    }
}

function Test-RegisterStep-DuplicateNumberError {
    Initialize-StepState
    $exitCode = 0
    try {
        . $stepRunner
        Register-Step -Id "first" -Number 1 -Name "First" -Action { $true }
        Register-Step -Id "second" -Number 1 -Name "Second" -Action { $true }
    } catch {
        $exitCode = 1
    }
    if ($exitCode -eq 1) {
        Assert-Pass "Register-Step duplicate number errors (Spec A)"
    } else {
        Assert-Fail "Register-Step dup num" "Expected error for duplicate number"
    }
}

# ---- Spec A: Step number derivation from NN- filename prefix ----

function Test-RegisterStep-DeriveNumberFromFilename {
    Initialize-StepState
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("step-runner-test-" + [System.IO.Path]::GetRandomFileName())
    try {
        $null = New-Item -ItemType Directory -Path $tmpDir  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded
        $fakeStep = Join-Path $tmpDir '05-fake.ps1'
        Set-Content -Path $fakeStep -Encoding utf8 -Value @(
            ". '$stepRunner'"
            "Register-Step -Id 'fake' -Name 'Fake' -Action { Write-Output (Get-StepNumber) }"
        )
        . $fakeStep

        if ($script:StepNumbers.Count -eq 1 -and $script:StepNumbers[0] -eq 5) {
            Assert-Pass "Register-Step derives step number from NN- filename prefix"
        } else {
            $num = if ($script:StepNumbers.Count -eq 1) { $script:StepNumbers[0] } else { "none" }
            Assert-Fail "Register-Step derive number" "Expected number 5, got $num"
        }

        $output = & $script:StepActions[0]
        if ($output -eq 5) {
            Assert-Pass "Get-StepNumber returns the step number inside a step action"
        } else {
            Assert-Fail "Get-StepNumber" "Expected output 5, got '$output'"
        }
    } finally {
        if ($tmpDir -and (Test-Path $tmpDir)) {
            # check-suppress:suppression_doc: best-effort temp-dir cleanup; dir may already be gone.
            Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-RegisterStep-DeriveNumberThrowsWithoutPrefix {
    Initialize-StepState
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("step-runner-test-" + [System.IO.Path]::GetRandomFileName())
    $exitCode = 0
    try {
        $null = New-Item -ItemType Directory -Path $tmpDir  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded
        $plainStep = Join-Path $tmpDir 'plain.ps1'
        Set-Content -Path $plainStep -Encoding utf8 -Value @(
            ". '$stepRunner'"
            "Register-Step -Id 'fake' -Name 'Fake' -Action { Write-Output (Get-StepNumber) }"
        )
        . $plainStep
    } catch {
        $exitCode = 1
    } finally {
        if ($tmpDir -and (Test-Path $tmpDir)) {
            # check-suppress:suppression_doc: best-effort temp-dir cleanup; dir may already be gone.
            Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if ($exitCode -eq 1 -and $script:StepNumbers.Count -eq 0) {
        Assert-Pass "Register-Step without NN- prefix errors and registers no step"
    } else {
        Assert-Fail "Register-Step derive error" "Expected error and 0 steps registered, got $($script:StepNumbers.Count) steps"
    }
}

# ---- Spec B: Applicability matrix (Get-StepRunState) ----

function Test-RunState-Platform {
    Initialize-StepState
    . $stepRunner

    # Exactly one platform applies to this host; the other names its token and value.
    $offHost = if ($IsWindows) { 'posix' } else { 'windows' }
    $offHostState = Get-StepRunState -Id 'x' -Platform $offHost -Mode any -Requires none
    $anyState = Get-StepRunState -Id 'x' -Platform any -Mode any -Requires none

    if ($offHostState -eq "not applicable (platform: $offHost)" -and $null -eq $anyState) {
        Assert-Pass "platform applicability: off-host declares not applicable, any runs"
    } else {
        Assert-Fail "platform applicability" "offHost='$offHostState' any='$anyState'"
    }
}

function Test-RunState-Mode {
    Initialize-StepState
    . $stepRunner

    $script:HAS_ARGS = $true
    $scopedState = Get-StepRunState -Id 'x' -Platform any -Mode scoped -Requires none
    $fullState = Get-StepRunState -Id 'x' -Platform any -Mode full -Requires none

    $script:HAS_ARGS = $false
    $scopedOffState = Get-StepRunState -Id 'x' -Platform any -Mode scoped -Requires none
    $fullOffState = Get-StepRunState -Id 'x' -Platform any -Mode full -Requires none

    if ($null -eq $scopedState -and $fullState -eq 'not applicable (mode: full)' -and
        $scopedOffState -eq 'not applicable (mode: scoped)' -and $null -eq $fullOffState) {
        Assert-Pass "mode applicability tracks the scoped/full run"
    } else {
        Assert-Fail "mode applicability" "scoped='$scopedState' full='$fullState' scopedOff='$scopedOffState' fullOff='$fullOffState'"
    }
}

function Test-RunState-Prerequisite {
    Initialize-StepState
    . $stepRunner

    $script:ONLINE = $false
    $offlineState = Get-StepRunState -Id 'x' -Platform any -Mode any -Requires network
    $noneState = Get-StepRunState -Id 'x' -Platform any -Mode any -Requires none

    $script:ONLINE = $true
    $onlineState = Get-StepRunState -Id 'x' -Platform any -Mode any -Requires network

    if ($offlineState -eq 'not applicable (requires: network)' -and $null -eq $onlineState -and $null -eq $noneState) {
        Assert-Pass "requires applicability: network needs --online, none always runs"
    } else {
        Assert-Fail "requires applicability" "offline='$offlineState' online='$onlineState' none='$noneState'"
    }
}

function Test-RunState-NotSelected {
    Initialize-StepState
    . $stepRunner

    $script:OnlySteps = @('chosen')
    $chosenState = Get-StepRunState -Id 'chosen' -Platform any -Mode any -Requires none
    $otherState = Get-StepRunState -Id 'other' -Platform any -Mode any -Requires none

    if ($null -eq $chosenState -and $otherState -eq 'not-selected') {
        Assert-Pass "--only-steps marks every unselected step not-selected"
    } else {
        Assert-Fail "not-selected state" "chosen='$chosenState' other='$otherState'"
    }
}

function Test-RunState-SelectionPrecedence {
    Initialize-StepState
    . $stepRunner

    # An unselected step reports not-selected, not a platform/mode/requires reason.
    $script:OnlySteps = @('chosen')
    $state = Get-StepRunState -Id 'other' -Platform windows -Mode full -Requires nix

    if ($state -eq 'not-selected') {
        Assert-Pass "selection is reported before applicability"
    } else {
        Assert-Fail "selection precedence" "Expected 'not-selected', got '$state'"
    }
}

# ---- Spec C: --only-steps flag (via Read-Argument) ----

function Test-OnlySteps-EqualsForm {
    Initialize-StepState
    . $stepRunner
    Register-Step -Id "alpha" -Number 1 -Name "Alpha" -Action { $true }
    Register-Step -Id "beta" -Number 2 -Name "Beta" -Action { $true }

    Read-Argument -Arguments @('--only-steps=alpha,beta')

    if ($script:OnlySteps.Count -eq 2 -and $script:OnlySteps[0] -eq 'alpha' -and $script:OnlySteps[1] -eq 'beta') {
        Assert-Pass "--only-steps=alpha,beta populates OnlySteps with two entries"
    } else {
        Assert-Fail "--only-steps equals" "Expected 2 entries ['alpha','beta'], got $($script:OnlySteps.Count): $($script:OnlySteps -join ',')"
    }
}

function Test-OnlySteps-EmptyValue {
    Initialize-StepState
    . $stepRunner
    Register-Step -Id "alpha" -Number 1 -Name "Alpha" -Action { $true }

    Read-Argument -Arguments @('--only-steps=')

    if ($script:OnlySteps.Count -eq 0) {
        Assert-Pass "--only-steps= results in an empty selection"
    } else {
        Assert-Fail "--only-steps empty" "Expected 0 entries, got $($script:OnlySteps.Count)"
    }
}

function Test-OnlySteps-Dedup {
    Initialize-StepState
    . $stepRunner
    Register-Step -Id "alpha" -Number 1 -Name "Alpha" -Action { $true }

    Read-Argument -Arguments @('--only-steps=alpha,alpha')

    if ($script:OnlySteps.Count -eq 1 -and $script:OnlySteps[0] -eq 'alpha') {
        Assert-Pass "--only-steps=alpha,alpha deduplicates to one entry"
    } else {
        Assert-Fail "--only-steps dedup" "Expected 1 entry 'alpha', got $($script:OnlySteps.Count): $($script:OnlySteps -join ',')"
    }
}

function Test-OnlySteps-LastValueWin {
    Initialize-StepState
    . $stepRunner
    Register-Step -Id "alpha" -Number 1 -Name "Alpha" -Action { $true }
    Register-Step -Id "beta" -Number 2 -Name "Beta" -Action { $true }

    Read-Argument -Arguments @('--only-steps=alpha', '--only-steps=beta')

    if ($script:OnlySteps.Count -eq 1 -and $script:OnlySteps[0] -eq 'beta') {
        Assert-Pass "--only-steps last value wins (no accumulation)"
    } else {
        Assert-Fail "--only-steps last-win" "Expected ['beta'], got $($script:OnlySteps -join ',')"
    }
}

function Test-OnlySteps-UnknownIdError {
    Initialize-StepState
    . $stepRunner
    Register-Step -Id "alpha" -Number 1 -Name "Alpha" -Action { $true }

    $threw = $false
    $message = ''
    try {
        Read-Argument -Arguments @('--only-steps=nonexistent-id')
    } catch {
        $threw = $true
        $message = $_.Exception.Message
    }

    if ($threw -and $message.Contains("unknown step id 'nonexistent-id' in --only-steps (known: alpha)")) {
        Assert-Pass "--only-steps with an unknown ID is a hard error"
    } else {
        Assert-Fail "--only-steps unknown" "threw=$threw message='$message'"
    }
}

# ---- Shared test state ----

function Initialize-StepState {
    $script:StepIds = [System.Collections.Generic.List[string]]::new()
    $script:StepNumbers = [System.Collections.Generic.List[int]]::new()
    $script:StepNames = [System.Collections.Generic.List[string]]::new()
    $script:StepActions = [System.Collections.Generic.List[scriptblock]]::new()
    $script:StepPlatforms = [System.Collections.Generic.List[string]]::new()
    $script:StepModes = [System.Collections.Generic.List[string]]::new()
    $script:StepRequires = [System.Collections.Generic.List[string]]::new()
    $script:OnlySteps = @()
    $script:NotRunStates = @{}
    $script:ONLINE = $false
    $script:HAS_ARGS = $false
    $script:usageAction = { Write-Output "usage: test" }
}

# ---- Fail-fast reporting ----

# A fail-fast abort exits before Format-StepSummary, which is the only other place
# captured step output is replayed; the failing step's output must still be shown.
function Test-FailFastReport-ReplaysFailedStep {
    Initialize-StepState
    . $stepRunner

    # The entry points import Format-NucleusOutput.psm1; stub the reporter it provides.
    function Write-ErrorMessage { param([string]$Message) Write-Output "error: $Message" }

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "nucleus-failfast-test-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Path $tempDir -Force > $null
    try {
        $script:WaveTmpDir = $tempDir
        $script:NucStyleDim = ''
        $script:NucStyleReset = ''
        $script:NucStyleRed = ''
        Register-Step -Id "bad" -Number 1 -Name "Bad step" -Action { $true }
        "why-it-failed" | Out-File -FilePath (Join-Path $tempDir "step-1.out") -Encoding utf8
        "5" | Out-File -FilePath (Join-Path $tempDir "step-1.time") -Encoding utf8 -NoNewline

        $out = Format-FailFastReport -Number @(1) 2>&1 | Out-String

        if ($out -match 'Bad step' -and $out -match 'why-it-failed' -and $out -match 'some checks failed: steps 1 ') {
            Assert-Pass "a fail-fast abort reports the failing step and its output"
        } else {
            Assert-Fail "Format-FailFastReport" "expected step name, replayed output and failure message; got [$out]"
        }
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force
    }
}

# ---- Run tests ----
Write-Output "`n=== Step-runner framework unit tests (PS1) ==="
Write-Output "Registration arity, token validation, applicability matrix, --only-steps."
Write-Output ""

Test-RegisterStep-WithId
Test-RegisterStep-MultipleWithId
Test-RegisterStep-DeclaredToken
Test-RegisterStep-UndeclaredDefault
Test-RegisterStep-UnknownToken
Test-RegisterStep-IdWithDigitError
Test-RegisterStep-EmptyIdError
Test-RegisterStep-DuplicateIdError
Test-RegisterStep-DuplicateNumberError
Test-RegisterStep-DeriveNumberFromFilename
Test-RegisterStep-DeriveNumberThrowsWithoutPrefix

Test-RunState-Platform
Test-RunState-Mode
Test-RunState-Prerequisite
Test-RunState-NotSelected
Test-RunState-SelectionPrecedence

Test-OnlySteps-EqualsForm
Test-OnlySteps-EmptyValue
Test-OnlySteps-Dedup
Test-OnlySteps-LastValueWin
Test-OnlySteps-UnknownIdError
Test-FailFastReport-ReplaysFailedStep

Write-Output "`n--- Step-runner PS1 unit tests: $($script:passCount) passed, $($script:failCount) failed ---"
Write-Output ""

exit $script:failCount
