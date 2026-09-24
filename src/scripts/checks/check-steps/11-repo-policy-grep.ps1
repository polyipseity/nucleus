Register-Step -Id "repo-policy-grep" -Name "Repository policy (grep-heavy)" -Action {
  param([Parameter(Mandatory)][PSObject]$Context)

  $HasArgs = $Context.HasArgs
  $RepoRoot = $Context.RepoRoot
  $PositionalArgs = $Context.PositionalArgs

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  # WHY: all repo-policy step files must be excluded from pattern scans to avoid self-referencing literal pattern text
  $allStepLeaves = @('11-repo-policy-grep.ps1', '12-repo-policy-pattern.ps1', '13-repo-policy-data.ps1', '14-repository-policy.ps1')
  $failed = $false

  # --- Package manager enforcement ---
  Write-Message "--- package manager enforcement ---"
  $pmeViolations = 0
  $pmeExcludeNames = @('check.sh', 'check.ps1', 'shell.nix') + $allStepLeaves

  if ($HasArgs) {
    $pmeHasShell = @($PositionalArgs | Where-Object { $_ -match '\.(sh|ps1|nix)$' }).Count -gt 0
    if (-not $pmeHasShell) {
      Write-Message "0 shell files in scope — nothing to enforce."
    } else {
      $pmeGrepFiles = @(
        $PositionalArgs | Where-Object { $_ -match '\.(sh|ps1|nix)$' } |
        Where-Object { $pmeExcludeNames -notcontains [System.IO.Path]::GetFileName($_) }
      )
      if ($pmeGrepFiles.Count -gt 0) {
        $pipV = Select-String -Path $pmeGrepFiles -Pattern '(^|[^a-z])pip install([^-]|$)' |
          Where-Object { $_.Line -notmatch 'uv pip install' }
        if ($pipV) { Write-ErrorMessage 'bare pip install detected (use uv pip install instead)'; $pmeViolations++ }

        $npmV = Select-String -Path $pmeGrepFiles -Pattern '(^|[^a-z])npm install([^-]|$)'
        if ($npmV) { Write-ErrorMessage 'bare npm install detected (use bun or nix instead)'; $pmeViolations++ }
      }
    }
  } else {
    $pmeGrepFiles = @(
      Get-ChildItem -Recurse -Path (Join-Path $r 'scripts'), (Join-Path $r 'src'), (Join-Path $r 'tests') `
        -Include *.sh, *.ps1, *.nix `
        -Exclude check.sh, check.ps1, shell.nix `
        | Where-Object { $allStepLeaves -notcontains $_.Name } `
        | ForEach-Object { $_.FullName }
    )
    if ($pmeGrepFiles.Count -gt 0) {
      $pipV = Select-String -Path $pmeGrepFiles -Pattern '(^|[^a-z])pip install([^-]|$)' |
        Where-Object { $_.Line -notmatch 'uv pip install' }
      if ($pipV) { Write-ErrorMessage 'bare pip install detected (use uv pip install instead)'; $pmeViolations++ }

      $npmV = Select-String -Path $pmeGrepFiles -Pattern '(^|[^a-z])npm install([^-]|$)'
      if ($npmV) { Write-ErrorMessage 'bare npm install detected (use bun or nix instead)'; $pmeViolations++ }
    }
  }

  # Self-pruning: verify excluded files still justify their exclusion (A1)
  foreach ($ef in @('check.sh', 'check.ps1', 'shell.nix')) {
    $efPath = Join-Path $r $ef
    if ((Test-Path $efPath) -and -not (Select-String -LiteralPath $efPath -Pattern '(pip install|npm install)' -Quiet)) {
      Write-ErrorMessage "stale exclusion: '$ef' no longer contains pip/npm install patterns — remove from -Exclude list"
      $pmeViolations++
    }
  }

  if ($pmeViolations -gt 0) { $failed = $true } else { Write-Message 'no package manager violations found.' }

  # --- Suppression audit ---
  Write-Message "--- suppression audit ---"
  $saUndocViolations = @()
  $saHasFiles = $false
  $saFileCache = @{}

  function Test-Suppressed {
    param([string]$CheckId, [string]$Path, [int]$LineNumber, [ref]$Cache)
    if (-not $Cache.Value.ContainsKey($Path)) { $Cache.Value[$Path] = @(Get-Content -Path $Path) }
    $content = $Cache.Value[$Path]
    $line = $content[$LineNumber - 1]
    if ($line -match "# check-suppress:$CheckId[\s:]") { return $true }
    if ($LineNumber -gt 1) {
      $prevLine = $content[$LineNumber - 2]
      if ($prevLine -match "# check-suppress:$CheckId[\s:]") { return $true }
    }
    return $false
  }

  function Get-UndocSuppViolation {
    param(
      [string]$Pattern, [string]$Label, [switch]$IsRegex,
      [string[]]$Files, [string]$CheckId = 'suppression_doc',
      [switch]$NoSuppressionCheck, [ref]$Cache
    )
    $result = @()
    if ($Files.Count -eq 0) { return $result }
    try {
      $selParams = @{ Path = $Files; AllMatches = $true; Pattern = $Pattern; SimpleMatch = -not $IsRegex }
      foreach ($m in (Select-String @selParams)) {
        if ($m.Line -match '^\s*#') { continue }
        if (-not $NoSuppressionCheck -and (Test-Suppressed -CheckId $CheckId -Path $m.Path -LineNumber $m.LineNumber -Cache $Cache)) { continue }
        if ($m.LineNumber -gt 1 -and -not $NoSuppressionCheck) {
          if (-not $Cache.Value.ContainsKey($m.Path)) { $Cache.Value[$m.Path] = @(Get-Content -Path $m.Path) }
          if ($Cache.Value[$m.Path][$m.LineNumber - 2] -match "# check-suppress:$CheckId") { continue }
        }
        $result += "$($m.Path):$($m.LineNumber) ($Label)"
      }
    } catch { Write-WarningMessage "Error scanning for $Label`: $_" }
    return $result
  }

  if ($HasArgs) {
    $saShFiles = @(if ($Context.ShFiles) { $Context.ShFiles } else { $PositionalArgs | Where-Object { $_ -like '*.sh' } })
    $saNixFiles = @(if ($Context.NixFiles) { $Context.NixFiles } else { $PositionalArgs | Where-Object { $_ -like '*.nix' } })
    $saPs1Files = @((@(if ($Context.Ps1Files) { $Context.Ps1Files } else { $PositionalArgs | Where-Object { $_ -like '*.ps1' } })) |
      Where-Object { (Split-Path -Leaf $_) -notin $allStepLeaves })
    $saHasFiles = ($saShFiles.Count -gt 0) -or ($saNixFiles.Count -gt 0) -or ($saPs1Files.Count -gt 0)

    $saUndocViolations += Get-UndocSuppViolation -Pattern '|| true' -Label '|| true' -Files @(($saShFiles + $saNixFiles) | Where-Object { $_ -notmatch '(^|[\\/])tests[\\/]' }) -Cache ([ref]$saFileCache)
    $saUndocViolations += Get-UndocSuppViolation -Pattern '2>$null' -Label '2>$null' -Files $saPs1Files -Cache ([ref]$saFileCache)
    $saUndocViolations += Get-UndocSuppViolation -Pattern '-ErrorAction SilentlyContinue' -Label '-ErrorAction SilentlyContinue' -Files $saPs1Files -Cache ([ref]$saFileCache)
    $saUndocViolations += Get-UndocSuppViolation -Pattern 'catch\s*\{\s*\}' -Label 'empty catch {}' -IsRegex -Files $saPs1Files -Cache ([ref]$saFileCache)
    $saUndocViolations += Get-UndocSuppViolation -Pattern '\| Out-Null' -Label '| Out-Null' -IsRegex -Files $saPs1Files -NoSuppressionCheck -Cache ([ref]$saFileCache)
    $saUndocViolations += Get-UndocSuppViolation -Pattern '\$null\s*=\s*\S' -Label '$null =' -IsRegex -Files $saPs1Files -Cache ([ref]$saFileCache)
    $saUndocViolations += Get-UndocSuppViolation -Pattern '\[void\]' -Label '[void]' -IsRegex -Files $saPs1Files -Cache ([ref]$saFileCache)
    $saUndocViolations += Get-UndocSuppViolation -Pattern 'SuppressMessageAttribute\(' -Label 'SuppressMessageAttribute' -IsRegex -Files $saPs1Files -CheckId 'SuppressMessageAttribute' -Cache ([ref]$saFileCache)
  } else {
    $saAllShNix = @(
      Get-ChildItem -Path $r -Recurse -File |
        Where-Object { $_.Extension -in '.sh', '.nix' -and $_.FullName -notmatch '[\/]vendor[\/]' } |
        ForEach-Object { $_.FullName }
    )
    $saAllPs1 = @(
      Get-ChildItem -Path $r -Recurse -File |
        Where-Object { $_.Extension -eq '.ps1' -and $_.FullName -notmatch '[\/]vendor[\/]' -and $_.Name -notin $allStepLeaves } |
        ForEach-Object { $_.FullName }
    )
    $saHasFiles = ($saAllShNix.Count -gt 0) -or ($saAllPs1.Count -gt 0)

    $saUndocViolations += Get-UndocSuppViolation -Pattern '|| true' -Label '|| true' -Files @($saAllShNix | Where-Object { $_ -notmatch '(^|[\\/])tests[\\/]' }) -Cache ([ref]$saFileCache)
    $saUndocViolations += Get-UndocSuppViolation -Pattern '2>$null' -Label '2>$null' -Files $saAllPs1 -Cache ([ref]$saFileCache)
    $saUndocViolations += Get-UndocSuppViolation -Pattern '-ErrorAction SilentlyContinue' -Label '-ErrorAction SilentlyContinue' -Files $saAllPs1 -Cache ([ref]$saFileCache)
    $saUndocViolations += Get-UndocSuppViolation -Pattern 'catch\s*\{\s*\}' -Label 'empty catch {}' -IsRegex -Files $saAllPs1 -Cache ([ref]$saFileCache)
    $saUndocViolations += Get-UndocSuppViolation -Pattern '\| Out-Null' -Label '| Out-Null' -IsRegex -Files $saAllPs1 -NoSuppressionCheck -Cache ([ref]$saFileCache)
    $saUndocViolations += Get-UndocSuppViolation -Pattern '\$null\s*=\s*\S' -Label '$null =' -IsRegex -Files $saAllPs1 -Cache ([ref]$saFileCache)
    $saUndocViolations += Get-UndocSuppViolation -Pattern '\[void\]' -Label '[void]' -IsRegex -Files $saAllPs1 -Cache ([ref]$saFileCache)
    $saUndocViolations += Get-UndocSuppViolation -Pattern 'SuppressMessageAttribute\(' -Label 'SuppressMessageAttribute' -IsRegex -Files $saAllPs1 -CheckId 'SuppressMessageAttribute' -Cache ([ref]$saFileCache)
  }

  if ($saUndocViolations.Count -gt 0) {
    foreach ($uv in ($saUndocViolations | Sort-Object -Unique)) { Write-ErrorMessage $uv }
    Write-ErrorMessage "suppression audit failed with $($saUndocViolations.Count) violation(s)"
    Write-Message "  add '# check-suppress:suppression_doc: reason' comment to explain intentional suppressions."
    $failed = $true
  } elseif (-not $saHasFiles) {
    Write-Message '0 script files in scope — nothing to audit.'
  } else {
    Write-Message 'no suppression audit violations found.'
  }

  if ($failed) {
    Write-ErrorMessage "repository policy (grep-heavy) check failed"
    return $false
  }

  Write-Message "repository policy (grep-heavy) passed."
  return $true
}
