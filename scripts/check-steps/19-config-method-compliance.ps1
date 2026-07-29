Register-Step -Number 19 -Name "Config method compliance" -Action {
  param($Step, $HasArgs, $RepoRoot, $WaveTmpDir, $PositionalArgs)

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  $cfgDir = Join-Path -Path $r -ChildPath "src\modules\configs"
  $cfgErrors = 0

  # Single-pass: collect all config file basenames, run one Select-String across src/
  $cfgFiles = Get-ChildItem -Path $cfgDir -Recurse -File
  $srcFiles = Get-ChildItem -Path (Join-Path $r "src") -Recurse -Include '*.nix', '*.ps1', '*.sh' |
    Where-Object { $_.FullName -notmatch '[\\/]vendor[\\/]' -and $_.FullName -notmatch '[\\/]configs[\\/]' }
  $cfgPatterns = @($cfgFiles | ForEach-Object { [regex]::Escape($_.Name) } | Sort-Object -Unique)
  $cfgSelectOutput = $srcFiles | Select-String -Pattern $cfgPatterns -SimpleMatch
  # Single-pass: collect all # Method lines for preceding-line checking
  $cfgMethodOutput = $srcFiles | Select-String -Pattern '# Method'

  $parallelJobs = [Environment]::ProcessorCount

  $cfgFileErrors = $cfgFiles | ForEach-Object -Parallel -ThrottleLimit $using:parallelJobs {
    $basename = $_.Name

    # Skip infrastructure files and Nix modules inside configs/
    if ($basename -in '.gitkeep', '.gitignore') { return $null }
    if ($basename -like '*.schema.json') { return $null }
    if ($basename -eq 'qtpass.nix') { return $null }

    # Skip agent customization files (consumed as a directory via Method 4)
    $relPath = $_.FullName.Substring($using:cfgDir.Length + 1) -replace '\\', '/'
    if ($relPath -like 'agents/*') { return $null }

    # Check against cached Select-String output -- relative path first, then basename
    $refs = @($using:cfgSelectOutput | Where-Object { $_.Line -match [regex]::Escape($relPath) })
    if ($refs.Count -eq 0) {
      $refs = @($using:cfgSelectOutput | Where-Object { $_.Line -match [regex]::Escape($basename) })
    }

    if ($refs.Count -eq 0) {
      return "$relPath : no references found in src/ (excluding configs/) -- orphaned config?"
    }

    $hasMethod = $false
    foreach ($ref in $refs) {
      if ($ref.Line -match '# Method') {
        $hasMethod = $true
        break
      }
      # Check preceding line using cached # Method output
      if ($ref.LineNumber -gt 1) {
        $prevLineNum = $ref.LineNumber - 1
        $prevMatch = $using:cfgMethodOutput | Where-Object { $_.Path -eq $ref.Path -and $_.LineNumber -eq $prevLineNum }
        if ($prevMatch) {
          $hasMethod = $true
          break
        }
      }
    }
    if (-not $hasMethod) {
      return "$relPath : referenced but no '# Method N' comment found on or before reference lines"
    }

    return $null
  }

  foreach ($cfe in $cfgFileErrors) {
    if ($cfe) {
      Write-ErrorMessage $cfe
      $cfgErrors++
    }
  }

  if ($cfgErrors -gt 0) {
    Write-ErrorMessage "config method compliance check failed with $cfgErrors error(s)"
    return $false
  }

  Write-Message "config method compliance passed."
  return $true
}
