# test.ps1 — Repository test suite runner (Windows).
#
# Runs all Windows-compatible repository test suites in sequence:
#
# Test suites (1-5):
#
# Code quality tests (2-3):
#   2. Shell script linting (stub — requires POSIX/ShellCheck)
#   3. PowerShell lint (PSScriptAnalyzer)
#
# Functional tests (1, 4-5):
#   1. Nix test suite (stub — requires POSIX/Nix)
#   4. Nucleus apps smoke tests (stub — requires Nix/bash)
#   5. System config build (stub — POSIX-only)
#
# Mode taxonomy:
#   No --scoped/--full distinction (all steps always run). Use --skip-system-build
#   to skip step 5.
#
# Output conventions:
#   All messages (info, success, skip, warning) go to stdout.
#   This differs from test.sh, which routes warnings to stderr — the
#   split is intentional per platform convention.
#   Use test.sh's header comment as the cross-reference source of truth
#   for the POSIX-side convention.
#
# Dependencies policy:
# Every external tool required by any step in this script MUST be declared in
# the pre-flight block below. Missing tools cause an immediate hard failure —
# steps MUST NEVER silently skip due to missing dependencies.
# The pre-flight block is the single source of truth for all tool requirements.
# To add a new tool-using step, first add it to pre-flight, then provision it
# on all target hosts.
#
# File discovery policy:
# Nix test discovery is dynamic on POSIX (find tests/ -name '*.nix').
# PowerShell files are auto-discovered by check-pwsh.ps1.
#
# Note: Steps 1, 2, 4, 5 are stubs on Windows (POSIX/Nix/bash toolchain not available).
#       --quiet is only supported on POSIX (test.sh); accepted as no-op on Windows.
#
# Prerequisites:
#   - PSScriptAnalyzer module (Install-Module PSScriptAnalyzer -Scope CurrentUser)
#   - Ensure-Tool module (imported via pre-flight block) for tool validation
#
# Arguments:
#   --fail-fast         Exit immediately on first failure (default).
#   --no-fail-fast      Accumulate all failures.
#   --skip-system-build No-op (accepted for CLI parity with test.sh).
#   --quiet             No-op (--quiet is POSIX-only; accepted for CLI parity).
#
# Environment variables:
#   NUCLEUS_REPO_ROOT  Override the detected repository root path.
#
# Exit conditions:
#   0 on success; non-zero on any check failure.
# By default, fail-fast is enabled (exit immediately on first failure).
# Use --no-fail-fast to accumulate all failures.

#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = if ($env:NUCLEUS_REPO_ROOT) { $env:NUCLEUS_REPO_ROOT } else { Split-Path -Parent $PSScriptRoot }
$exitCode = 0
$FAIL_FAST = $true
$_step = 0

# Output helpers — structured prefix pattern matching section()/say/warn from test.sh.
function say { Write-Output "test: $args" }
function warn { Write-Output "test: warning: $args" }

# Pre-flight tool availability checks.
# All tools listed in Prerequisites must be present. Missing tools produce
# an immediate hard failure — run nucleus-apply to install them.
$modulesPath = Join-Path $PSScriptRoot '..\src\hosts\Windows\modules'
Import-Module (Join-Path $modulesPath 'Ensure-Tool.psm1') -Force
# PSScriptAnalyzer is required for PowerShell lint step 3
Ensure-Tool -Name 'PSScriptAnalyzer' -Type 'Module' -InstallCommand "Install-Module PSScriptAnalyzer -Scope CurrentUser -Force"

# Process flags
foreach ($_arg in $args) {
  if ($_arg -eq '-h' -or $_arg -eq '--help') {
    Write-Output "Usage: test.ps1 [--fail-fast|--no-fail-fast] [--skip-system-build] [--quiet]"
    Write-Output "  Run all Windows-compatible repository test suites."
    Write-Output "  --fail-fast            Exit immediately on first failure (default)."
    Write-Output "  --no-fail-fast          Accumulate all failures."
    Write-Output "  --skip-system-build     No-op (accepted for CLI parity with test.sh)."
    Write-Output "  --quiet                No-op (--quiet is POSIX-only; accepted for CLI parity)."
    exit 0
  } elseif ($_arg -eq '--fail-fast') {
    $FAIL_FAST = $true
  } elseif ($_arg -eq '--no-fail-fast') {
    $FAIL_FAST = $false
  } elseif ($_arg -eq '--skip-system-build') {
    # No-op: accepted for CLI parity with test.sh.
  } elseif ($_arg -eq '--quiet') {
    # No-op: --quiet is POSIX-only.
  } else {
    Write-Output "test: error: unrecognized argument: $_arg"
    exit 1
  }
}
# Cache file lists — used by active steps to avoid repeated discovery.
$script:CachedPs1Files = Get-ChildItem -Recurse -Path $RepoRoot -Filter '*.ps1' | Where-Object { $_.FullName -notmatch '[/\\]vendor[/\\]' } | Sort-Object FullName

# Wave parallelism infrastructure: each step writes its exit code to a per-step temp file.
# Results are aggregated at the end. In FAIL_FAST mode, steps run sequentially (original behavior).
$script:WaveTmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
$null = New-Item -ItemType Directory -Path $script:WaveTmpDir
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Remove-Item -Recurse -Force $script:WaveTmpDir -ErrorAction SilentlyContinue } | Out-Null # check-suppress:suppression_doc: cleanup of temp dir in %TEMP%; failure is harmless on process exit

# ---------------------------------------------------------------------------
# 1. Nix test suite — POSIX only (stub on Windows)
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] Nix test suite ===" -f (++$_step))
say "skipping (requires Nix toolchain — not available on Windows)."

# ---------------------------------------------------------------------------
# 2. Shell script linting — POSIX only (stub on Windows)
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] Shell script linting ===" -f (++$_step))
say "skipping (requires ShellCheck — not available on Windows)."

# ---------------------------------------------------------------------------
# 3. PowerShell lint (PSScriptAnalyzer)
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] PowerShell lint ===" -f (++$_step))
$script:waveJob3 = Start-Job -ScriptBlock {
  param($pwshScript)
  & $pwshScript
  $LASTEXITCODE
} -ArgumentList "$PSScriptRoot\check-pwsh.ps1"

# ---------------------------------------------------------------------------
# 4. Nucleus apps smoke tests — POSIX only (stub on Windows)
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] Nucleus apps smoke tests ===" -f (++$_step))
say "skipping (requires Nix and bash — not available on Windows)."

# ---------------------------------------------------------------------------
# 5. System config build — POSIX only (stub on Windows)
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] System config build ===" -f (++$_step))
say "skipping (system config build is POSIX-only)."

# Wait for background jobs and collect exit codes
if ($script:waveJob3) {
  $result = $script:waveJob3 | Wait-Job | Receive-Job
  $result | Out-File -FilePath (Join-Path $script:WaveTmpDir "step-3.exit") -NoNewline
}

# Wave result aggregation — collect step exit codes from temp files
foreach ($_s in @(1, 2, 3, 4)) {
  $_exitFile = Join-Path $script:WaveTmpDir "step-$_s.exit"
  if (Test-Path $_exitFile) {
    $_code = Get-Content $_exitFile -Raw | ForEach-Object { $_.Trim() }
    if ($_code -ne '0') {
      $exitCode = 1
      if ($FAIL_FAST) { exit $exitCode }
    }
  }
}

Write-Output ""
if ($exitCode -ne 0) {
  warn "some tests failed with exit code $exitCode"
  exit $exitCode
}
say "all tests passed."
