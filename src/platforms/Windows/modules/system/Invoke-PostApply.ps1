<#
.SYNOPSIS
  Execute post-apply provisioning steps on Windows.

.DESCRIPTION
  Runs best-effort post-apply operations after the system configuration has
  been converged: service verification, archiving stack check, AI model sync,
  replica sync, VM setup/sync, garbage collection, and manual display.

  Each step is best-effort: failures warn but do not abort the apply.

.PARAMETER RepoRoot
  Absolute path to the nucleus repository root.

.PARAMETER NoAISync
  When set, skips the Ollama model sync step.

.PARAMETER ReplicaSync
  When set, runs cloud replica sync (default is skip).

.PARAMETER VMSetup
  When set, runs full VM provisioning instead of lightweight config sync.

.PARAMETER NoVMSync
  When set, skips the VM config sync step.

.PARAMETER ModuleDir
  Absolute path to the Windows modules directory (for gc.ps1).

.EXAMPLE
  Invoke-PostApply -RepoRoot $repoRoot -ModuleDir $systemModuleDir

.EXAMPLE
  Invoke-PostApply -RepoRoot $repoRoot -ModuleDir $systemModuleDir -NoAISync -VMSetup

.NOTES
  Exit codes:
    0 on success; 1 on error.
#>
function Invoke-PostApply {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [Parameter(Mandatory)]
    [string]$ModuleDir,

    [switch]$NoAISync,

    [switch]$ReplicaSync,

    [switch]$VMSetup,

    [switch]$NoVMSync
  )

  $ErrorActionPreference = "Stop"

  # ── Service verification ─────────────────────────────────────────
  $svcScript = Join-Path -Path $RepoRoot -ChildPath "scripts\svc.ps1"
  if (Test-Path -LiteralPath $svcScript) {
    try {
      & $svcScript verify
    } catch {
      Write-NucleusWarning -CommandName svc "some services are inactive (non-fatal; check Event Viewer for details)"
    }
  }

  # ── Archiving stack health check ────────────────────────────────
  Test-ArchivingStack > $null

  # ── AI model sync ────────────────────────────────────────────────
  if ($NoAISync) {
    Write-NucleusInfo -CommandName ai "-NoAISync set; skipping post-apply model sync"
  } else {
    # check-suppress:suppression_doc: probe whether ollama is installed (may not be on first-provision hosts).
    $ollamaOnPath = Get-Command -Name "ollama" -ErrorAction SilentlyContinue
    if ($null -eq $ollamaOnPath) {
      Write-NucleusInfo -CommandName ai "ollama not found in PATH; skipping post-apply model sync"
    } else {
      Write-NucleusInfo -CommandName ai "running post-apply AI model sync..."
      Invoke-AISync -RepoRoot $RepoRoot -ServerReadyTimeoutSeconds 60
    }
  }

  # ── Replica sync ─────────────────────────────────────────────────
  if (-not $ReplicaSync) {
    Write-NucleusInfo -CommandName replica-sync "skipping post-apply replica sync (default; pass -ReplicaSync to run now)"
  } else {
    # check-suppress:suppression_doc: probe -- rclone may be absent on first-provision hosts.
    $rcloneOnPath = Get-Command -Name "rclone" -ErrorAction SilentlyContinue
    if ($null -eq $rcloneOnPath) {
      Write-NucleusInfo -CommandName replica-sync "rclone not found in PATH; skipping post-apply replica sync"
    } else {
      Write-NucleusInfo -CommandName replica-sync "running post-apply replica sync..."
      try {
        Invoke-ReplicaSync -RepoRoot $RepoRoot
      } catch {
        Write-NucleusWarning -CommandName replica-sync "replica sync incomplete (system apply succeeded): $($_.Exception.Message)"
      }
    }
  }

  # ── VM post-apply ────────────────────────────────────────────────
  if ($VMSetup) {
    Write-NucleusInfo -CommandName vm-setup "running post-apply VM provisioning (setup)..."
    try {
      Invoke-VMSetup -RepoRoot $RepoRoot
    } catch {
      Write-NucleusWarning -CommandName vm-setup "VM setup incomplete (system apply succeeded): $($_.Exception.Message)"
    }
  } elseif ($NoVMSync) {
    Write-NucleusInfo -CommandName vm-sync "-NoVMSync set; skipping post-apply VM config refresh"
  } else {
    Write-NucleusInfo -CommandName vm-sync "running post-apply VM config refresh..."
    try {
      Invoke-VMSync -RepoRoot $RepoRoot
    } catch {
      Write-NucleusWarning -CommandName vm-sync "VM sync incomplete (system apply succeeded): $($_.Exception.Message)"
    }
  }

  # ── Garbage collection ───────────────────────────────────────────
  $gcScript = Join-Path -Path $RepoRoot -ChildPath "scripts\gc.ps1"
  if (-not (Test-Path -LiteralPath $gcScript)) {
    Write-NucleusInfo -CommandName gc "scripts/gc.ps1 not found; skipping garbage collection"
  } else {
    Write-NucleusInfo -CommandName gc "running post-apply garbage collection..."
    try {
      & $gcScript -ModuleDir $ModuleDir -RepoRoot $RepoRoot
    } catch {
      Write-NucleusWarning -CommandName gc "GC incomplete (system apply succeeded): $($_.Exception.Message)"
    }
  }

  # ── Manual display ───────────────────────────────────────────────
  $manualPath = Join-Path -Path $RepoRoot -ChildPath "src\hosts\Windows\MANUAL.md"
  if (Test-Path -LiteralPath $manualPath) {
    Write-Output "--- MANUAL SETUP (one-time, required) ---"
    Get-Content -Path $manualPath | Write-Output
    Write-Output "-------------------------------------------"
  }
}
