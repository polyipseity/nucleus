Register-Step -Id "repo-policy-grep" -Name "Repository policy (grep-heavy)" -Action {
  param([Parameter(Mandatory)][PSObject]$Context)

  $HasArgs = $Context.HasArgs
  $RepoRoot = $Context.RepoRoot
  $PositionalArgs = $Context.PositionalArgs

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  # WHY: all repo-policy step files must be excluded from pattern scans to avoid self-referencing literal pattern text
  $allStepLeaves = @('11-repo-policy-grep.ps1', '12-repo-policy-pattern.ps1', '13-repo-policy-data.ps1', '14-repository-policy.ps1')
  $allStepShLeaves = @('11-repo-policy-grep.sh', '12-repo-policy-pattern.sh', '13-repo-policy-data.sh', '14-repository-policy.sh')
  $failed = $false

  # --- Package manager enforcement ---
  Write-Message "--- package manager enforcement ---"
  $pmeViolations = 0
  $pmeExcludeNames = @('check.sh', 'check.ps1', 'shell.nix') + $allStepLeaves + $allStepShLeaves

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
        | Where-Object { $pmeExcludeNames -notcontains $_.Name } `
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

  # --- Cloud-mount invariants ---
  # The shared runner is backend-agnostic: FUSE and supervisor names live behind
  # the mount and supervisor interfaces, and the macOS installer has one site.
  Write-Message "--- cloud-mount invariants ---"
  $cmViolations = 0
  $cmOsPattern = 'macfuse|fskit|WinFsp|fuse3|nucleus-cloud-repair'

  foreach ($cmRelative in @('src/scripts/services/rclone-mount.sh', 'src/scripts/services/rclone-mount.ps1')) {
    $cmPath = Join-Path -Path $r -ChildPath $cmRelative
    if (-not (Test-Path -LiteralPath $cmPath)) { continue }
    if (Select-String -LiteralPath $cmPath -Pattern $cmOsPattern -Quiet) {
      Write-ErrorMessage "$cmRelative contains OS-specific FUSE/backend names (invariant violation: $cmOsPattern)"
      $cmViolations++
    }
  }

  $cmInstallDirs = @(
    @('src/scripts/lib', 'src/scripts/services') |
      ForEach-Object { Join-Path -Path $r -ChildPath $_ } |
      Where-Object { Test-Path -LiteralPath $_ }
  )
  $cmInstallSites = @()
  if ($cmInstallDirs.Count -gt 0) {
    $cmInstallSites = @(
      Get-ChildItem -LiteralPath $cmInstallDirs -Recurse -File |
        Select-String -Pattern 'macfuse install|brew install.*macfuse' -CaseSensitive |
        ForEach-Object { $_.Path } |
        Sort-Object -Unique
    )
  }
  if ($cmInstallSites.Count -ne 1) {
    Write-ErrorMessage "found $($cmInstallSites.Count) macfuse install call sites; must be exactly one (mount-backend-darwin.sh)"
    $cmViolations++
  }

  if ($cmViolations -gt 0) { $failed = $true } else { Write-Message 'no cloud-mount invariant violations found.' }

  # --- Service supervision invariants ---
  # The rewrite locked in one loop policy, one threshold source and one retry
  # owner for every service.  Every assertion below fails if a later change
  # reintroduces a second copy of one of them; none inspects service identity,
  # because loop protection is deliberately not configurable per service.
  Write-Message "--- service supervision invariants ---"
  $ssViolations = 0
  $ssHealthLib = 'src/scripts/lib/service-health.sh'
  $ssWatchdog = 'src/scripts/services/service-watchdog.sh'
  $ssServicesJson = 'src/modules/services.json'
  $ssScanDirs = @('src', 'scripts')
  # WHY: this step names the constants it verifies, so both variants of the step
  # are excluded from the reference scan to keep their verdicts identical
  $ssStepLeaves = @('11-repo-policy-grep.sh', '11-repo-policy-grep.ps1')

  # Thresholds live once, in the POSIX health library, and are compared there
  # only through their constants.  A second definition or a bare numeric
  # comparison is a second policy that can drift from the watchdog's.
  $ssHealthLibPath = Join-Path -Path $r -ChildPath $ssHealthLib
  if (Test-Path -LiteralPath $ssHealthLibPath) {
    foreach ($ssName in @('_SVC_HEALTH_LOOP_RESTARTS', '_SVC_HEALTH_LOOP_CONSECUTIVE', '_SVC_HEALTH_WARN_RESTARTS')) {
      $ssDefs = @(Select-String -LiteralPath $ssHealthLibPath -Pattern "^[ \t]*readonly $ssName=" -CaseSensitive).Count
      if ($ssDefs -ne 1) {
        Write-ErrorMessage "$ssHealthLib defines $ssName $ssDefs times; loop thresholds must have exactly one source"
        $ssViolations++
      }
    }

    $ssBare = @(Select-String -LiteralPath $ssHealthLibPath -Pattern '-(ge|gt|le|lt)\s+"?[0-9]+' -CaseSensitive)
    if ($ssBare.Count -gt 0) {
      $ssBareList = @($ssBare | ForEach-Object { "$($_.LineNumber):$($_.Line.Trim())" }) -join '; '
      Write-ErrorMessage "$ssHealthLib compares a bare numeric threshold; use the _SVC_HEALTH_* constants: $ssBareList"
      $ssViolations++
    }

    $ssElsewhere = @()
    foreach ($ssElsewhereDir in $ssScanDirs) {
      $ssElsewherePath = Join-Path -Path $r -ChildPath $ssElsewhereDir
      if (-not (Test-Path -LiteralPath $ssElsewherePath)) { continue }
      $ssElsewhere += @(
        Get-ChildItem -LiteralPath $ssElsewherePath -Recurse -File -Filter '*.sh' |
          Select-String -Pattern '_SVC_HEALTH_(LOOP|WARN)_[A-Z_]+' -CaseSensitive |
          Where-Object { $_.Path -ne $ssHealthLibPath } |
          Where-Object { $ssStepLeaves -notcontains [System.IO.Path]::GetFileName($_.Path) } |
          Where-Object { -not ($_.Line -match '^\s*#') }
      )
    }
    if ($ssElsewhere.Count -gt 0) {
      Write-ErrorMessage "the loop thresholds are referenced outside $ssHealthLib; they have one definition and one library"
      $ssViolations++
    }
  }

  # Loop protection is a property of the health record, never a per-service
  # setting.  Only each service entry's own keys are inspected, so the
  # legitimate cloud-drive.lifecycle block stays out of scope by design.
  $ssServicesJsonPath = Join-Path -Path $r -ChildPath $ssServicesJson
  if (Test-Path -LiteralPath $ssServicesJsonPath) {
    $ssServices = $null
    try {
      $ssServices = Get-Content -LiteralPath $ssServicesJsonPath -Raw | ConvertFrom-Json -AsHashtable
    } catch {
      Write-ErrorMessage "$ssServicesJson is not valid JSON; cannot verify the loop-policy invariants"
      $ssViolations++
    }
    if ($null -ne $ssServices) {
      $ssForbidden = @()
      foreach ($ssSvcKey in $ssServices.Keys) {
        if ($ssSvcKey.StartsWith('$')) { continue }
        $ssEntry = $ssServices[$ssSvcKey]
        if (-not ($ssEntry -is [System.Collections.IDictionary])) { continue }
        foreach ($ssFieldKey in $ssEntry.Keys) {
          if ($ssFieldKey -imatch 'loop|throttle|exempt') { $ssForbidden += "$ssSvcKey`: $ssFieldKey" }
        }
      }
      if ($ssForbidden.Count -gt 0) {
        Write-ErrorMessage "$ssServicesJson declares a per-service loop/throttle/exempt field: $((@($ssForbidden) | Sort-Object) -join '; ')"
        Write-ErrorMessage 'loop protection is uniform for every service; it must not become a per-service field'
        $ssViolations++
      }
    }
  }

  # The POSIX watchdog supervises through the supervisor interface alone; the
  # PowerShell it once carried made it unable to check anything on that host.
  $ssWatchdogPath = Join-Path -Path $r -ChildPath $ssWatchdog
  if ((Test-Path -LiteralPath $ssWatchdogPath) -and
      (Select-String -LiteralPath $ssWatchdogPath -Pattern 'ScheduledTask|schtask|ConvertTo-Json' -Quiet)) {
    Write-ErrorMessage "$ssWatchdog contains PowerShell; the POSIX watchdog runs on POSIX hosts only"
    $ssViolations++
  }

  # Retry and backoff belong to the shared runner alone.  A mount backend or the
  # setup step that sleeps is a second retry owner, which is how the original
  # restart storm ran without backoff.
  $ssMountFiles = @(
    'src/scripts/lib/mount-backend-darwin.sh',
    'src/scripts/lib/mount-backend-linux.sh',
    'src/scripts/services/cloud-drives-setup.sh'
  )
  foreach ($ssMountFile in $ssMountFiles) {
    $ssMountPath = Join-Path -Path $r -ChildPath $ssMountFile
    if (-not (Test-Path -LiteralPath $ssMountPath)) { continue }
    if (Select-String -LiteralPath $ssMountPath -Pattern '(^|[^a-zA-Z0-9_])sleep([^a-zA-Z0-9_]|$)' -CaseSensitive -Quiet) {
      Write-ErrorMessage "$ssMountFile sleeps; retry/backoff is owned by the shared runner (src/scripts/services/rclone-mount.sh)"
      $ssViolations++
    }
  }

  # Only the watchdog may act on the loop predicate.  A service script that
  # calls it is enforcing a private throttle instead of reporting health.
  $ssConsumerPaths = @()
  foreach ($ssConsumerDir in @('src/scripts', 'scripts')) {
    $ssConsumerRoot = Join-Path -Path $r -ChildPath $ssConsumerDir
    if (-not (Test-Path -LiteralPath $ssConsumerRoot)) { continue }
    $ssConsumerPaths += @(
      Get-ChildItem -LiteralPath $ssConsumerRoot -Recurse -File -Filter '*.sh' |
        Select-String -Pattern 'svc_health_is_looping\s+[^\s]' -CaseSensitive |
        Where-Object { -not ($_.Line -match '^\s*#') } |
        ForEach-Object { $_.Path }
    )
  }
  $ssAllowedConsumers = @('src/scripts/lib/service-health.sh', 'src/scripts/services/service-watchdog.sh')
  foreach ($ssConsumerPath in @($ssConsumerPaths | Sort-Object -Unique)) {
    $ssConsumerRelative = $ssConsumerPath.Substring($r.Length).TrimStart('/', '\')
    if ($ssAllowedConsumers -notcontains $ssConsumerRelative) {
      Write-ErrorMessage "$ssConsumerRelative calls svc_health_is_looping; the watchdog is the only loop-policy consumer"
      $ssViolations++
    }
  }

  if ($ssViolations -gt 0) { $failed = $true } else { Write-Message 'no service supervision invariant violations found.' }

  if ($failed) {
    Write-ErrorMessage "repository policy (grep-heavy) check failed"
    return $false
  }

  Write-Message "repository policy (grep-heavy) passed."
  return $true
}
