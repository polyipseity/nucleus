# provisioned-tools-drift.ps1 - provisioned tools instruction drift helper.
#
# Function definitions only; no top-level side effects. Dot-source this library
# from a step action runspace or tests that need the helper.

function Invoke-ProvisionedToolsInstructionDriftCheck {
  [CmdletBinding()]
  [OutputType([void])] # check-suppress:suppression_doc: declares void return by contract
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][ref]$Passed
  )

  $Passed.Value = $false

  $instrPath = Join-Path $RepoRoot 'src\users\default\agents\instructions\nucleus-provisioned-tools.instructions.md'
  if (-not (Test-Path -LiteralPath $instrPath)) {
    Write-ErrorMessage "nucleus provisioned tools instruction not found at $instrPath"
    return
  }

  $instrContent = Get-Content -LiteralPath $instrPath -Raw
  $corePath = Join-Path $RepoRoot 'src\modules\core.nix'
  $desiredPath = Join-Path $RepoRoot 'src\modules\packages\desired.json'
  $fontExclude = @('font-awesome', 'inter', 'jetbrains-mono-nerd-font', 'noto-sans-cjk-sc', 'noto-sans-cjk-tc', 'noto-serif-cjk-sc', 'noto-serif-cjk-tc', 'source-serif')
  $requiredNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

  # Required names are derived from source files: managedPackages CLI entries in
  # core.nix excluding font entries and the dummy default marker, unioned with
  # every package name in desired.json. Detection requires a backticked name in
  # the instruction so the list stays comprehensive.
  # Layout/block assumptions (matches current formatting): the managedPackages
  # block begins at `  managedPackages = {` and ends at `  };`; each top-level
  # entry header is indented 4 spaces (`    name = {` or quoted) and body braces
  # are tracked by line brace counts to find the entry end. A parse/block-mismatch
  # is intended to fail loudly as a safety signal rather than silently drift.
  if (-not (Test-Path -LiteralPath $corePath)) {
    Write-ErrorMessage "managedPackages source not found at $corePath"
    return
  }
  if (-not (Test-Path -LiteralPath $desiredPath)) {
    Write-ErrorMessage "desired package manifest not found at $desiredPath"
    return
  }

  $coreLines = Get-Content -LiteralPath $corePath
  $inManaged = $false
  $managedBlockFound = $false
  for ($i = 0; $i -lt $coreLines.Count; $i++) {
    if ($coreLines[$i] -eq '  managedPackages = {') { $inManaged = $true; $managedBlockFound = $true; continue }
    if ($inManaged -and $coreLines[$i] -eq '  };') { $inManaged = $false; break }
    if (-not $inManaged) { continue }

    $entryMatch = [regex]::Match($coreLines[$i], '^    "?([^"=]+?)"?\s*=\s*\{$')
    if (-not $entryMatch.Success) { continue }

    $name = $entryMatch.Groups[1].Value.Trim()
    $j = $i + 1
    $depth = 1
    $isCli = $false
    while ($j -lt $coreLines.Count -and $depth -gt 0) {
      $line = $coreLines[$j]
      if ($line -match 'category\s*=\s*"cli"') { $isCli = $true }
      $depth += ([regex]::Matches($line, '\{').Count - [regex]::Matches($line, '\}').Count)
      $j++
    }

    if ($isCli -and $name -ne 'default' -and ($fontExclude -notcontains $name)) {
      [void]$requiredNames.Add($name) # check-suppress:suppression_doc: discards HashSet.Add result; insertion is the only effect
    }
    $i = $j - 1
  }

  if (-not $managedBlockFound) {
    Write-ErrorMessage "managedPackages block not found in $corePath"
    return
  }

  $desired = Get-Content -LiteralPath $desiredPath -Raw | ConvertFrom-Json -AsHashtable
  foreach ($mgr in $desired.Keys) {
    if ($mgr -eq '$schema') { continue }
    $hostMap = $desired[$mgr]
    if ($null -eq $hostMap) { continue }
    foreach ($hostKey in $hostMap.Keys) {
      foreach ($pkg in @($hostMap[$hostKey])) {
        if ($null -ne $pkg -and $pkg.ContainsKey('name')) {
          [void]$requiredNames.Add([string]$pkg.name) # check-suppress:suppression_doc: discards HashSet.Add result; insertion is the only effect
        }
      }
    }
  }

  $backtick = [string][char]96
  $missingTools = @()
  foreach ($name in ($requiredNames | Sort-Object)) {
    $needle = $backtick + $name + $backtick
    if ($instrContent.IndexOf($needle, [System.StringComparison]::Ordinal) -lt 0) {
      $missingTools += $name
    }
  }

  if ($missingTools.Count -gt 0) {
    Write-ErrorMessage "nucleus provisioned tools instruction is missing required tool name(s):"
    foreach ($name in $missingTools) {
      Write-ErrorMessage "  $name"
    }
    return
  }

  Write-Message "provisioned tools instruction drift policy passed."
  $Passed.Value = $true
}
