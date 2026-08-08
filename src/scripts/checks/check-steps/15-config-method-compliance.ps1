Register-Step -Id "config-method-compliance" -Number 15 -Name "Config method compliance" -Action {
  param($RepoRoot)

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  $cfgDir = Join-Path -Path $r -ChildPath "src\modules\configs"
  $cfgErrors = 0

  # Single-pass: collect all config file basenames, run one Select-String across src/
  $cfgFiles = Get-ChildItem -Path $cfgDir -Recurse -File
  $srcFiles = Get-ChildItem -Path (Join-Path $r "src") -Recurse -Include '*.nix', '*.ps1', '*.sh' |
    Where-Object { $_.FullName -notmatch '[\/]vendor[\/]' -and $_.FullName -notmatch '[\/]configs[\/]' } |
    Select-GitIgnored  # ref: allow-and-deny-lists.instructions.md#B1 -- structural invariants; vendored code and config methods are different concerns; gitignore filter applied on top
  # WHY: raw basenames with -SimpleMatch mirror the .sh twin's grep -F -f semantics; [regex]::Escape here would make dotted basenames (e.g. system.gitconfig) match literally and never be found
  $cfgPatterns = @($cfgFiles | ForEach-Object { $_.Name } | Sort-Object -Unique)
  # WHY: Select-GitIgnored returns path strings; piping strings to Select-String searches them as content, so -Path is required to read the actual files
  $cfgSelectOutput = Select-String -Path $srcFiles -Pattern $cfgPatterns -SimpleMatch
  # Single-pass: collect all check-suppress:config-method lines for preceding-line checking
  $cfgMethodOutput = Select-String -Path $srcFiles -Pattern '# check-suppress:config-method'
  # WHY: refs may use a ${hostName} template (e.g. git/${hostName}.gitconfig) that no
  # raw basename substring-matches; gather those lines for per-file resolution below.
  $cfgTemplateOutput = Select-String -Path $srcFiles -Pattern '${hostName}' -SimpleMatch

  $parallelJobs = [Environment]::ProcessorCount

  # WHY: $using: is only valid inside the -Parallel scriptblock; -ThrottleLimit is
  # evaluated in the caller scope, so it takes the plain variable (canonical order:
  # scriptblock first, then -ThrottleLimit)
  $cfgFileErrors = $cfgFiles | ForEach-Object -Parallel {
    $basename = $_.Name

    # Skip infrastructure files and Nix modules inside configs/  # ref: allow-and-deny-lists.instructions.md#A2 -- infrastructure files are not configs
    if ($basename -in '.gitkeep', '.gitignore') { return $null }
    if ($basename -like '*.schema.json') { return $null }

    # Skip agent customization files (consumed as a directory via Method 4)  # ref: allow-and-deny-lists.instructions.md#A2 -- agents/* consumed as directory
    $relPath = $_.FullName.Substring($using:cfgDir.Length + 1) -replace '\\', '/'
    if ($relPath -like 'agents/*') { return $null }

    # Check against cached Select-String output -- relative path first, then basename
    $refs = @($using:cfgSelectOutput | Where-Object { $_.Line -match [regex]::Escape($relPath) })
    if ($refs.Count -eq 0) {
      $refs = @($using:cfgSelectOutput | Where-Object { $_.Line -match [regex]::Escape($basename) })
    }
    if ($refs.Count -eq 0) {
      # WHY: ${hostName}.gitconfig references every host's config (MacBook/NixOS/Windows.gitconfig);
      # match template lines by the basename's extension suffix.
      $dotIndex = $basename.IndexOf('.')
      if ($dotIndex -gt 0) {
        $templateSuffix = [regex]::Escape($basename.Substring($dotIndex))
        $refs = @($using:cfgTemplateOutput | Where-Object { $_.Line -match ('\$\{hostName\}' + $templateSuffix) })
      }
    }

    if ($refs.Count -eq 0) {
      return "$relPath : no references found in src/ (excluding configs/) -- orphaned config?"
    }

    $hasMethod = $false
    foreach ($ref in $refs) {
      if ($ref.Line -match '# check-suppress:config-method') {
        $hasMethod = $true
        break
      }
      # Check preceding line using cached check-suppress:config-method output
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
      return "$relPath : referenced but no '# check-suppress:config-method' comment found on or before reference lines"
    }

    return $null
  } -ThrottleLimit $parallelJobs

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
