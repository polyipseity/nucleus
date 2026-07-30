Register-Step -Number 13 -Name "Schema validation (JSON/YAML)" -Action {
  param($Step, $HasArgs, $RepoRoot, $WaveTmpDir, $PositionalArgs)

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  # Build manifest of file->schema pairs.
  $manifest = [System.Collections.Generic.List[hashtable]]::new()

  if ($HasArgs) {
    foreach ($sf in $PositionalArgs) {
      if ($sf -like '*.json') {
        $schema = try { (Get-Content $sf -Raw | ConvertFrom-Json -AsHashtable)['$schema'] } catch { $null }
        if ($schema) {
          if ($schema -match '^\.') {
            $schemafile = [System.IO.Path]::GetFullPath((Join-Path (Split-Path $sf -Parent) $schema))
          } else {
            $schemafile = $schema
          }
          $manifest.Add(@{SchemaFile = $schemafile; InstanceFile = $sf })
        }
      } elseif ($sf -like '*.yml' -or $sf -like '*.yaml') {
        $schema = try { ($sf | Get-Content -Raw | ConvertFrom-Yaml)['$schema'] } catch { $null }
        if ($schema) {
          if ($schema -match '^\.') {
            $schemafile = [System.IO.Path]::GetFullPath((Join-Path (Split-Path $sf) $schema))
          } else {
            $schemafile = $schema
          }
          $manifest.Add(@{SchemaFile = $schemafile; InstanceFile = $sf })
        }
      }
    }
  } else {
    # JSON files
    Get-ChildItem -Recurse -Path "$r/src" -Filter '*.json' | Where-Object {
      $_.FullName -notmatch '[/\]vendor[/\]' -and $_.Name -notlike '*.schema.json'  # ref: allow-and-deny-lists.instructions.md#B3,#A7 — reason: structural invariants; schema files are meta
    } | ForEach-Object {
      $schema = try { (Get-Content $_.FullName -Raw | ConvertFrom-Json -AsHashtable)['$schema'] } catch { $null }
      if ($schema) {
        if ($schema -match '^\.') {
          $schemafile = [System.IO.Path]::GetFullPath((Join-Path $_.DirectoryName $schema))
        } else {
          $schemafile = $schema
        }
        $manifest.Add(@{SchemaFile = $schemafile; InstanceFile = $_.FullName })
      }
    }
    # YAML files
    Get-ChildItem -Recurse -Path $r -Include '*.yml', '*.yaml' | Where-Object {
      $_.FullName -notmatch '[/\]vendor[/\]' -and $_.FullName -notmatch '[/\]secrets[/\]'  # ref: allow-and-deny-lists.instructions.md#B3 — reason: structural invariants
    } | ForEach-Object {
      $schema = try { ($_ | Get-Content -Raw | ConvertFrom-Yaml)['$schema'] } catch { $null }
      if ($schema) {
        if ($schema -match '^\.') {
          $schemafile = [System.IO.Path]::GetFullPath((Join-Path $_.DirectoryName $schema))
        } else {
          $schemafile = $schema
        }
        $manifest.Add(@{SchemaFile = $schemafile; InstanceFile = $_.FullName })
      }
    }
  }

  $jsonschemaErrors = 0
  if ($manifest.Count -gt 0) {
    # Group by schemafile and validate sequentially.
    $groups = $manifest | Group-Object SchemaFile
    foreach ($group in $groups) {
      $schemaFile = $group.Name
      $instanceFiles = @($group.Group.InstanceFile)
      $output = check-jsonschema --schemafile $schemaFile $instanceFiles 2>&1
      if ($LASTEXITCODE -ne 0) {
        $jsonschemaErrors++
        Write-ErrorMessage "$output"
      }
    }
  }

  # GitHub schema validation -- always-run
  $ghWorkflows = Join-Path $r '.github\workflows\*.yml'
  check-jsonschema --builtin-schema vendor.github-workflows $ghWorkflows
  if ($LASTEXITCODE -ne 0) { $jsonschemaErrors++ }

  $dependabot = Join-Path $r '.github\dependabot.yml'
  if (Test-Path $dependabot) {
    check-jsonschema --builtin-schema vendor.dependabot $dependabot
    if ($LASTEXITCODE -ne 0) { $jsonschemaErrors++ }
  }

  if ($jsonschemaErrors -gt 0) {
    Write-ErrorMessage "schema validation failed with $jsonschemaErrors error(s)"
    return $false
  }
  Write-Message "schema validation passed."
  return $true
}
