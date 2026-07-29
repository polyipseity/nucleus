Register-Step -Number 12 -Name "Locked DSC validation" -Action {
  param($Step, $HasArgs, $RepoRoot, $WaveTmpDir, $PositionalArgs)

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  # Helper: convert mixed PSCustomObject/hashtable/list trees to pure hashtable/array.
  function ConvertTo-HashtableDeep ($obj) {
    if ($obj -is [PSCustomObject]) {
      $ht = [ordered] @{}
      $obj.PSObject.Properties | ForEach-Object { $ht[$_.Name] = ConvertTo-HashtableDeep $_.Value }
      return $ht
    }
    if ($obj -is [array] -or $obj -is [System.Collections.IList]) {
      $result = @(); foreach ($item in $obj) { $result += ConvertTo-HashtableDeep $item }; return , $result
    }
    if ($obj -is [hashtable] -or $obj -is [System.Collections.Specialized.OrderedDictionary]) {
      $ht = @{}
      foreach ($key in $obj.Keys) { $ht[$key] = ConvertTo-HashtableDeep $obj[$key] }
      return $ht
    }
    return $obj
  }

  # Helper: normalize resources (which may arrive in columnar OrderedDictionary/hashtable
  # format from powershell-yaml on Windows CI) to a flat array of resource items.
  function ConvertTo-ResourceArray ($resources) {
    if ($null -eq $resources) { return , @() }
    if ($resources -is [array] -or $resources -is [System.Collections.IList]) { return , @($resources) }
    if ($resources -is [System.Collections.IDictionary]) {
      $keys = @($resources.Keys)
      if ($keys.Count -gt 0) {
        $firstVal = $resources[$keys[0]]
        if ($null -ne $firstVal -and ($firstVal -is [array] -or $firstVal -is [System.Collections.IList])) {
          # Columnar format -- unpivot into individual items.
          $count = $firstVal.Count
          $result = @()
          for ($i = 0; $i -lt $count; $i++) {
            $item = @{}
            foreach ($key in $keys) {
              $val = $resources[$key]
              if ($null -ne $val -and ($val -is [array] -or $val -is [System.Collections.IList]) -and $i -lt $val.Count) {
                $item[$key] = $val[$i]
              }
            }
            $result += $item
          }
          return , $result
        }
      }
      return , @($resources)
    }
    return , @($resources)
  }

  $dscSystemDir = Join-Path $r 'src\hosts\Windows\system'
  $dscSystemPackages = Join-Path $r 'src\hosts\Windows\system\packages.dsc.yml'
  $lockfilePath = Join-Path $r 'src\lockfiles\lockfile.json'
  $lfErrors = 0

  # Generate locked DSC in-memory from all system DSC files + lockfile.
  $lockfileData = Get-Content $lockfilePath -Raw | ConvertFrom-Json -AsHashtable
  # Read all system DSC files (sorted by name), excluding packages.dsc.yml.
  $dscSystemFiles = Get-ChildItem (Join-Path $dscSystemDir '*.dsc.yml') | Where-Object { $_.Name -ne 'packages.dsc.yml' } | Sort-Object Name
  if ($dscSystemFiles.Count -eq 0) {
    Write-ErrorMessage "no system DSC files found in $dscSystemDir"
    return $false
  }
  # Initialize DSC from the first file's structure.
  $dscYaml = Get-Content $dscSystemFiles[0].FullName -Raw
  $dsc = ConvertTo-HashtableDeep ($dscYaml | ConvertFrom-Yaml)
  $dsc.properties.resources = ConvertTo-ResourceArray $dsc.properties.resources
  # Merge resources from remaining system DSC files.
  foreach ($file in $dscSystemFiles[1..($dscSystemFiles.Count - 1)]) {
    $fileYaml = Get-Content $file.FullName -Raw
    $fileDsc = ConvertTo-HashtableDeep ($fileYaml | ConvertFrom-Yaml)
    $fileDsc.properties.resources = ConvertTo-ResourceArray $fileDsc.properties.resources
    $dsc.properties.resources += $fileDsc.properties.resources
  }
  # Merge package resources from system/packages.dsc.yml into the main DSC tree.
  $dscPkgYaml = Get-Content $dscSystemPackages -Raw
  $dscPkg = ConvertTo-HashtableDeep ($dscPkgYaml | ConvertFrom-Yaml)
  $dscPkg.properties.resources = ConvertTo-ResourceArray $dscPkg.properties.resources
  $dsc.properties.resources += $dscPkg.properties.resources

  # Inject version pins from lockfile into WinGet resources.
  foreach ($resource in $dsc.properties.resources) {
    if ($resource.resource -eq 'Microsoft.WinGet.Client/Package' -and $resource.settings.source -eq 'winget') {
      $id = $resource.settings.id
      if ($lockfileData.winget.ContainsKey($id) -and $lockfileData.winget[$id]) {
        $resource.settings | Add-Member -NotePropertyName version -NotePropertyValue $lockfileData.winget[$id] -Force
      }
    }
  }

  # Validate generated pins match lockfile entries.
  foreach ($resource in $dsc.properties.resources) {
    $hasVer = $resource.settings.PSObject.Properties.Name -contains 'version'
    if ($resource.resource -eq 'Microsoft.WinGet.Client/Package' `
        -and $resource.settings.source -eq 'winget' `
        -and $hasVer) {
      $id = $resource.settings.id
      $pinnedVer = $resource.settings.version
      $lfVer = if ($lockfileData.winget.ContainsKey($id)) { $lockfileData.winget[$id] } else { '' }

      if ([string]::IsNullOrEmpty($lfVer)) {
        Write-ErrorMessage "system DSC files: $id has version $pinnedVer but no lockfile entry"
        $lfErrors++
      } elseif ($pinnedVer -ne $lfVer) {
        Write-ErrorMessage "system DSC files: $id pinned $pinnedVer but lockfile has $lfVer"
        $lfErrors++
      }
    }
  }

  # Check for lockfile entries missing version pins in generated output.
  foreach ($entry in $lockfileData.winget.GetEnumerator()) {
    $id = $entry.Key
    $lfVer = $entry.Value
    $foundPin = $false
    foreach ($resource in $dsc.properties.resources) {
      $hasVer = $resource.settings.PSObject.Properties.Name -contains 'version'
      if ($resource.resource -eq 'Microsoft.WinGet.Client/Package' `
          -and $resource.settings.source -eq 'winget' `
          -and $resource.settings.id -eq $id `
          -and $hasVer) {
        $foundPin = $true
        break
      }
    }
    if (-not $foundPin) {
      Write-ErrorMessage "$id ($lfVer) is in lockfile but missing version pin after generation"
      $lfErrors++
    }
  }

  if ($lfErrors -gt 0) {
    Write-ErrorMessage "locked DSC validation failed with $lfErrors error(s)"
    return $false
  }

  Write-Message "locked DSC validation passed"
  return $true
}
