Register-Step -Id "suppression-audit" -Name "Suppression audit" -Action {
  param($HasArgs, $RepoRoot, $PositionalArgs)

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  $undocSuppViolations = @()
  $hasFiles = $false
  $script:fileCache = @{}

  function Test-Suppressed {
    param([string]$CheckId, [string]$Path, [int]$LineNumber)
    if (-not $script:fileCache.ContainsKey($Path)) {
      $script:fileCache[$Path] = @(Get-Content -Path $Path)
    }
    $content = $script:fileCache[$Path]
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
      [string]$Pattern,
      [string]$Label,
      [switch]$IsRegex,
      [string[]]$Files,
      [string]$CheckId = 'suppression_doc',
      [switch]$NoSuppressionCheck
    )
    $result = @()
    if ($Files.Count -eq 0) { return $result }
    try {
      $selParams = @{ Path = $Files; AllMatches = $true; Pattern = $Pattern; SimpleMatch = -not $IsRegex }
      $selMatches = Select-String @selParams
      foreach ($m in $selMatches) {
        # Skip comment-only lines (PowerShell #, bash #, Nix #)
        if ($m.Line -match '^\s*#') { continue }
        # Skip lines with check-suppress:<CheckId> inline
        if (-not $NoSuppressionCheck) {
          if (Test-Suppressed -CheckId $CheckId -Path $m.Path -LineNumber $m.LineNumber) { continue }
        }
        # Skip if preceding line has suppression comment
        if ($m.LineNumber -gt 1 -and -not $NoSuppressionCheck) {
          if (-not $script:fileCache.ContainsKey($m.Path)) { $script:fileCache[$m.Path] = @(Get-Content -Path $m.Path) }
          $prevLine = $script:fileCache[$m.Path][$m.LineNumber - 2]
          if ($prevLine -match "# check-suppress:$CheckId") { continue }
        }
        $result += "$($m.Path):$($m.LineNumber) ($Label)"
      }
    } catch {
      Write-Warning "Error scanning for $Label`: $_"
    }
    return $result
  }

  if ($HasArgs) {
    # WHY: if-statement output is pipeline-enumerated — an empty else branch yields $null, crashing the .Count checks below under StrictMode; the @() wrapper forces an array
    $shFiles = @(if ($script:SH_FILES) { $script:SH_FILES } else { $PositionalArgs | Where-Object { $_ -like '*.sh' } })
    $nixFiles = @(if ($script:NIX_FILES) { $script:NIX_FILES } else { $PositionalArgs | Where-Object { $_ -like '*.nix' } })
    $ps1Files = @(if ($script:PS1_FILES) { $script:PS1_FILES } else { $PositionalArgs | Where-Object { $_ -like '*.ps1' } })
    $ps1Files = @($ps1Files | Where-Object { (Split-Path -Leaf $_) -ne (Split-Path -Leaf $PSCommandPath) })  # ref: allow-and-deny-lists.instructions.md#A9 -- self-reference: scan definitions contain the literal suppression patterns being detected
    $hasFiles = ($shFiles.Count -gt 0) -or ($nixFiles.Count -gt 0) -or ($ps1Files.Count -gt 0)

    $undocSuppViolations += Get-UndocSuppViolation -Pattern '|| true' -Label '|| true' -Files @(($shFiles + $nixFiles) | Where-Object { $_ -notmatch '(^|[\\/])tests[\\/]' })
    $undocSuppViolations += Get-UndocSuppViolation -Pattern '2>$null' -Label '2>$null' -Files $ps1Files
    $undocSuppViolations += Get-UndocSuppViolation -Pattern '-ErrorAction SilentlyContinue' -Label '-ErrorAction SilentlyContinue' -Files $ps1Files
    $undocSuppViolations += Get-UndocSuppViolation -Pattern 'catch\s*\{\s*\}' -Label 'empty catch {}' -IsRegex -Files $ps1Files
    $undocSuppViolations += Get-UndocSuppViolation -Pattern '\| Out-Null' -Label '| Out-Null' -IsRegex -Files $ps1Files -NoSuppressionCheck
    $undocSuppViolations += Get-UndocSuppViolation -Pattern '\$null\s*=\s*\S' -Label '$null =' -IsRegex -Files $ps1Files
    $undocSuppViolations += Get-UndocSuppViolation -Pattern '\[void\]' -Label '[void]' -IsRegex -Files $ps1Files
    $undocSuppViolations += Get-UndocSuppViolation -Pattern 'SuppressMessageAttribute\(' -Label 'SuppressMessageAttribute' -IsRegex -Files $ps1Files -CheckId 'SuppressMessageAttribute'
  } else {
    $allShNix = @(
      Get-ChildItem -Recurse -Path $r -Include '*.sh', '*.nix' |
        Where-Object { $_.FullName -notmatch '[\/]vendor[\/]' } |  # ref: allow-and-deny-lists.instructions.md#B5 -- structural invariant
        ForEach-Object { $_.FullName }
    )
    $allPs1 = @(
      Get-ChildItem -Recurse -Path $r -Include '*.ps1' |
        Where-Object { $_.FullName -notmatch '[\/]vendor[\/]' } |  # ref: allow-and-deny-lists.instructions.md#B5 -- structural invariant
        Where-Object { $_.Name -ne (Split-Path -Leaf $PSCommandPath) } |  # ref: allow-and-deny-lists.instructions.md#A9 -- self-reference: scan definitions contain the literal suppression patterns being detected
        ForEach-Object { $_.FullName }
    )
    $hasFiles = ($allShNix.Count -gt 0) -or ($allPs1.Count -gt 0)

    $undocSuppViolations += Get-UndocSuppViolation -Pattern '|| true' -Label '|| true' -Files @($allShNix | Where-Object { $_ -notmatch '(^|[\\/])tests[\\/]' })
    $undocSuppViolations += Get-UndocSuppViolation -Pattern '2>$null' -Label '2>$null' -Files $allPs1
    $undocSuppViolations += Get-UndocSuppViolation -Pattern '-ErrorAction SilentlyContinue' -Label '-ErrorAction SilentlyContinue' -Files $allPs1
    $undocSuppViolations += Get-UndocSuppViolation -Pattern 'catch\s*\{\s*\}' -Label 'empty catch {}' -IsRegex -Files $allPs1
    $undocSuppViolations += Get-UndocSuppViolation -Pattern '\| Out-Null' -Label '| Out-Null' -IsRegex -Files $allPs1 -NoSuppressionCheck
    $undocSuppViolations += Get-UndocSuppViolation -Pattern '\$null\s*=\s*\S' -Label '$null =' -IsRegex -Files $allPs1
    $undocSuppViolations += Get-UndocSuppViolation -Pattern '\[void\]' -Label '[void]' -IsRegex -Files $allPs1
    $undocSuppViolations += Get-UndocSuppViolation -Pattern 'SuppressMessageAttribute\(' -Label 'SuppressMessageAttribute' -IsRegex -Files $allPs1 -CheckId 'SuppressMessageAttribute'
  }

  if ($undocSuppViolations.Count -gt 0) {
    foreach ($uv in ($undocSuppViolations | Sort-Object -Unique)) {
      Write-ErrorMessage $uv
    }
    Write-ErrorMessage "suppression audit failed with $($undocSuppViolations.Count) violation(s)"
    Write-Message "  add '# check-suppress:suppression_doc: reason' comment to explain intentional suppressions."
    return $false
  }

  if (-not $hasFiles) {
    Write-Message "==== $(Get-StepNumber): Suppression audit ==== SKIPPED (no script files to check)"
    return 2
  }

  Write-Message "no suppression audit violations found."
  return $true
}
