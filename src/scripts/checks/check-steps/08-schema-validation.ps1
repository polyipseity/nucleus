Register-Step -Id "schema-validation" -Number 8 -Name "Schema validation (JSON/YAML)" -Action {
  param($HasArgs, $RepoRoot, $PositionalArgs)

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
      $_.FullName -notmatch '[/\\]vendor[/\\]' -and $_.Name -notlike '*.schema.json'  # ref: allow-and-deny-lists.instructions.md#B3,#A7 -- structural invariants; schema files are meta
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
      $_.FullName -notmatch '[/\\]vendor[/\\]'  # ref: allow-and-deny-lists.instructions.md#B3 -- structural invariant; gitignore filter applied on top
    } | Select-GitIgnored | ForEach-Object {
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

  # $schema presence and format check (Spec G)


  # Collect all files in scope for $schema presence check
  $allFiles = [System.Collections.Generic.List[string]]::new()
  if ($HasArgs) {
    foreach ($sf in $PositionalArgs) {
      if ($sf -like '*.json' -or $sf -like '*.yml' -or $sf -like '*.yaml') {
        $allFiles.Add($sf)
      }
    }
  } else {
    Get-ChildItem -Recurse -Path "$r/src" -Filter '*.json' | Where-Object {
      $_.FullName -notmatch '[/\\]vendor[/\\]' -and $_.Name -notlike '*.schema.json'  # ref: allow-and-deny-lists.instructions.md#B3,#A7 -- structural invariants; schema files are meta
    } | ForEach-Object { $allFiles.Add($_.FullName) }
    Get-ChildItem -Recurse -Path $r -Include '*.yml', '*.yaml' | Where-Object {
      $_.FullName -notmatch '[/\\]vendor[/\\]'  # ref: allow-and-deny-lists.instructions.md#B3 -- structural invariant; gitignore filter applied on top
    } | Select-GitIgnored | ForEach-Object { $allFiles.Add($_.FullName) }
  }

  foreach ($f in $allFiles) {
    # Exception list: *.schema.json, vendor/**, secrets/**,
    # */.github/workflows/*.yml, */.github/dependabot.yml, package.json, opencode.jsonc
    # + app-owned formats with no published JSON schema (vscode:// URIs are not
    # fetchable by check-jsonschema; other formats have no published schema).
    $skipFile = $false
    if ($f -like '*.schema.json' -or $f -like '*\vendor\*' -or $f -like '*/vendor/*' -or `
        $f -like '*\secrets\*' -or $f -like '*/secrets/*' -or `
        $f -like '*.github\workflows\*' -or $f -like '*.github/workflows/*' -or `
        $f -like '*.github\dependabot.yml' -or $f -like '*.github/dependabot.yml' -or `
        $f -like '*users\*\vscode\*.json' -or $f -like '*users/*/vscode/*.json' -or `
        $f -like '*users\*\iterm2\DynamicProfiles\*.json' -or $f -like '*users/*/iterm2/DynamicProfiles/*.json' -or `
        $f -like '*users\*\obsidian\*.json' -or $f -like '*users/*/obsidian/*.json' -or `
        $f -like '*users\*\qtpass\*.json' -or $f -like '*users/*/qtpass/*.json' -or `
        $f -like '*configs\camilladsp\*' -or $f -like '*configs/camilladsp/*' -or `
        $f -like '*configs\camillagui-backend\*' -or $f -like '*configs/camillagui-backend/*' -or `
        $f -like '*users\*\discord-music-rpc\*' -or $f -like '*users/*/discord-music-rpc/*' -or `
        $f -like '*users\*\agents\hooks\*.json' -or $f -like '*users/*/agents/hooks/*.json' -or `
        $f -like '*users\*\agents\skills\*\_meta.json' -or $f -like '*users/*/agents/skills/*/_meta.json' -or `
        $f -like '*ai\litellm-config.yml' -or $f -like '*ai/litellm-config.yml' -or `
        $f -like '*\.sops.yaml' -or $f -like '*/.sops.yaml') { $skipFile = $true }
    if (-not $skipFile) {
      $fileName = Split-Path $f -Leaf
      if ($fileName -in @('package.json', 'opencode.jsonc')) { $skipFile = $true }
    }
    if ($skipFile) { continue }

    if ($f -like '*.json') {
      $content = try { Get-Content $f -Raw | ConvertFrom-Json -AsHashtable } catch { $null }
      $hasSchema = $content -and $content.ContainsKey('$schema')
      if ($hasSchema) {
        $schemaVal = $content['$schema']
        if ([string]::IsNullOrEmpty($schemaVal)) {
          Write-ErrorMessage "Invalid `$schema in ${f}: must be a non-empty string"
          $jsonschemaErrors++
        }
      } else {
        Write-ErrorMessage "Missing `$schema in $f"
        $jsonschemaErrors++
      }
    } elseif ($f -like '*.yml' -or $f -like '*.yaml') {
      $content = try { Get-Content $f -Raw | ConvertFrom-Yaml } catch { $null }
      $hasSchema = $content -and $content.ContainsKey('$schema')
      if ($hasSchema) {
        $schemaVal = $content['$schema']
        if ([string]::IsNullOrEmpty($schemaVal)) {
          Write-ErrorMessage "Invalid `$schema in ${f}: must be a non-empty string"
          $jsonschemaErrors++
        }
      } else {
        Write-ErrorMessage "Missing `$schema in $f"
        $jsonschemaErrors++
      }
    }
  }

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
