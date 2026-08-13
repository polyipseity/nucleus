# Step 14: autocompletion freshness (PowerShell).
#
# Verifies that the generated completer flag inventory in profile.ps1 matches
# scripts/gen-completions.ps1 (drift), that every nucleus-* command has both a
# zsh _nucleus-<cmd> file and a pwsh completer entry referencing its generated
# flag array (coverage), and that the -Sections value completion in the
# bump-lockfile completer still has its --list-sections contract (introspection).

Register-Step -Id "completions-fresh" -Name "Autocompletion freshness" -Action {
  param($RepoRoot)

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  # 1. Drift: the generated inventory must match scripts/gen-completions.ps1.
  Write-Message "--- generated completer inventory matches generator ---"
  & (Join-Path $r 'scripts\gen-completions.ps1') -Check
  if ($LASTEXITCODE -ne 0) {
    Write-ErrorMessage "src/scripts/shell/profile.ps1 is stale -- run scripts/gen-completions.ps1"
    return $false
  }

  # 2. Coverage: every nucleus-* command needs a zsh _nucleus-<cmd> file, a pwsh
  #    Register-ArgumentCompleter entry, and a generated $nucleus<Cmd>Flags array.
  Write-Message "--- coverage: zsh + pwsh completions for every nucleus-* command ---"
  $commands = @(
    'ai', 'apply', 'audit-store', 'bootstrap', 'bump-lockfile', 'check',
    'check-packer', 'check-pwsh', 'check-sh', 'cleanup-nix', 'cloud-setup',
    'config', 'gc', 'gs-pdf-opt', 'health-check', 'replica-reset',
    'replica-sync', 'service-watchdog', 'svc', 'test', 'update', 'vm'
  )
  $profilePath = Join-Path $r 'src/scripts/shell/profile.ps1'
  $zshDir = Join-Path $r 'src/modules/completions/zsh'
  $missing = @()
  foreach ($command in $commands) {
    $pascal = (($command.Split('-') | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) }) -join '')
    $flagVar = "`$nucleus${pascal}Flags"
    $hasZsh = Test-Path -Path (Join-Path $zshDir "_nucleus-$command") -PathType Leaf
    $hasCompleter = [bool](Select-String -Path $profilePath -Pattern "Register-ArgumentCompleter -CommandName nucleus-$command " -SimpleMatch -Quiet)
    $hasFlagVar = [bool](Select-String -Path $profilePath -Pattern $flagVar -SimpleMatch -Quiet)
    if (-not ($hasZsh -and $hasCompleter -and $hasFlagVar)) {
      $missing += "$command (zsh:$hasZsh completer:$hasCompleter flagvar:$hasFlagVar)"
    }
  }
  if ($missing.Count -gt 0) {
    Write-ErrorMessage "completions missing for: $($missing -join ', ')"
    return $false
  }

  # 3. Introspection contract: the bump-lockfile completer completes -Sections
  #    values via scripts/bump-lockfile.ps1 -ListSections; that parameter must
  #    exist.
  Write-Message "--- --list-* introspection contract ---"
  $bumpLockfilePath = Join-Path $r 'scripts\bump-lockfile.ps1'
  if (-not (Select-String -Path $bumpLockfilePath -Pattern 'ListSections' -SimpleMatch -Quiet)) {
    Write-ErrorMessage "scripts/bump-lockfile.ps1 lacks -ListSections, which the bump-lockfile completer depends on"
    return $false
  }

  Write-Message "completions are fresh."
  return $true
}
