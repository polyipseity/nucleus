<#
.SYNOPSIS
  Converge Jellyfin library folders from users.json declarations.

.DESCRIPTION
  Reads per-user jellyfin.libraries declarations, resolves ~ paths against
  each user's homeDirectory, resolves account credentials from per-user SOPS
  secrets, merges specs by name (first writer wins), and applies them via the
  Jellyfin HTTP API.  Runs after Sync-JellyfinAccount so accounts exist before
  library provisioning attempts authentication.

  API behavior source (upstream Jellyfin):
  - GET /Library/VirtualFolders
  - POST /Library/VirtualFolders?name=X&collectionType=Y
  - POST /Library/VirtualFolders/LibraryOptions
  Source: https://raw.githubusercontent.com/jellyfin/jellyfin/0beb07c40756aca5ab6a6ba4f8494bc5147e3c2b/Jellyfin.Api/Controllers/LibraryController.cs

.NOTES
  Environment variables:
    NUCLEUS_HOST  Host identifier for context-aware operations.

  Exit codes:
    This module does not emit exit codes.
#>
function Sync-JellyfinLibrary {
  <#
  .SYNOPSIS
    Converges Jellyfin library folders declared in users.json.

  .DESCRIPTION
    Reads per-user jellyfin.libraries declarations from the loaded Windows user
    registry records, resolves ~ paths against each user's homeDirectory,
    merges specs by library name (first writer wins), and applies them to the
    host-shared Jellyfin server.

    Authentication uses the same per-user secret pattern as Sync-JellyfinAccount:
    credentials are resolved from each user's src\secrets\users-<name>.yml via
    Get-Secret and tried against /Users/AuthenticateByName.  Startup bootstrap
    is attempted when no existing credential works.

    The function is idempotent:
      - Missing libraries are created.
      - Existing libraries have their LibraryOptions updated.
      - Libraries not in any declaration are left untouched.

  .PARAMETER RepoRoot
    Absolute path to the repository root.

  .PARAMETER UserRecords
    User records selected by apply.ps1 from the Windows user registry.

  .PARAMETER GpgExe
    Absolute path to gpg.exe for SOPS decryption fallback.

  .PARAMETER HostKeyPath
    Path to this machine's SSH host private key for age decryption.

  .PARAMETER PrimarySshKeyPath
    Path to the primary user's managed SSH private key for age fallback.

  .PARAMETER SopsExe
    Absolute path to sops.exe.

  .PARAMETER BaseUrl
    Jellyfin API base URL. Defaults to http://127.0.0.1:8096.

  .EXAMPLE
    Sync-JellyfinLibrary -RepoRoot 'C:\Users\admin\nucleus' -UserRecords $records `
      -GpgExe 'C:\Program Files\GnuPG\bin\gpg.exe' `
      -HostKeyPath 'C:\ProgramData\ssh\ssh_host_ed25519_key' `
      -PrimarySshKeyPath 'C:\Users\admin\.ssh\ssh_personal_admin' `
      -SopsExe 'C:\Users\admin\AppData\Local\Microsoft\WinGet\Packages\SecretsOPerationS.SOPS_...\sops.exe'

  .NOTES
    Environment variables:
      (none)    No environment variables used.

    Exit codes:
      0 on success; 1 on error.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [Parameter(Mandatory)]
    [array]$UserRecords,

    [Parameter(Mandatory)]
    [string]$GpgExe,

    [Parameter(Mandatory)]
    [string]$HostKeyPath,

    [Parameter(Mandatory)]
    [string]$PrimarySshKeyPath,

    [Parameter(Mandatory)]
    [string]$SopsExe,

    [string]$BaseUrl = 'http://127.0.0.1:8096'
  )

  # 1. Build library specs and collect auth credentials from all users.
  $librarySpecs = @()
  $authCreds = @()

  foreach ($userRecord in @($UserRecords)) {
    $libraries = @($userRecord.jellyfin.libraries | Where-Object { $_ })
    if ($libraries.Count -eq 0) {
      continue
    }

    $secretFile = Join-Path $RepoRoot "src\secrets\users-$($userRecord.name).yml"
    if (-not (Test-Path -LiteralPath $secretFile -PathType Leaf)) {
      Write-Warning "jellyfin/library: users-$($userRecord.name).yml not found; skipping library declarations for this user."
      continue
    }

    try {
      $secrets = Get-Secret -FilePath $secretFile -GpgExe $GpgExe -HostKeyPath $HostKeyPath -PrimarySshKeyPath $PrimarySshKeyPath -SopsExe $SopsExe
    }
    catch {
      Write-Warning "jellyfin/library: failed to decrypt $secretFile; skipping library declarations for $($userRecord.name): $($_.Exception.Message)"
      continue
    }

    # Resolve auth credentials from this user's jellyfin.accounts.
    $accounts = @($userRecord.jellyfin.accounts | Where-Object { $_ })
    foreach ($account in $accounts) {
      $usernameKey = [string]$account.usernameSecretKey
      $passwordKey = [string]$account.passwordSecretKey
      if ([string]::IsNullOrWhiteSpace($usernameKey) -or [string]::IsNullOrWhiteSpace($passwordKey)) {
        continue
      }
      $resolvedUsername = [string]$secrets.$usernameKey
      $resolvedPassword = [string]$secrets.$passwordKey
      if (-not [string]::IsNullOrWhiteSpace($resolvedUsername) -and -not [string]::IsNullOrWhiteSpace($resolvedPassword)) {
        $authCreds += [PSCustomObject]@{
          ownerUser = $userRecord.name
          username   = $resolvedUsername
          password   = $resolvedPassword
        }
      }
    }

    # Build library specs, resolving ~ paths against the user's homeDirectory.
    $homeDir = $userRecord.homeDirectory
    foreach ($lib in $libraries) {
      $resolvedPaths = @()
      foreach ($rawPath in @($lib.paths | Where-Object { $_ })) {
        $resolved = if ($rawPath -match '^~[/\\]') {
          Join-Path $homeDir $rawPath.Substring(2)
        }
        else {
          $rawPath
        }
        $resolvedPaths += $resolved
      }

      $librarySpecs += [PSCustomObject]@{
        ownerUser      = $userRecord.name
        name           = [string]$lib.name
        collectionType = [string]$lib.collectionType
        paths          = $resolvedPaths
        options        = $lib.options
      }
    }
  }

  if ($librarySpecs.Count -eq 0) {
    Write-Verbose 'jellyfin/library: no libraries declared; skipping.'
    return
  }

  # 2. Merge by name (first writer wins with warning).
  $mergedSpecs = @{}
  foreach ($spec in $librarySpecs) {
    $lowerName = $spec.name.ToLowerInvariant()
    if ($mergedSpecs.ContainsKey($lowerName)) {
      Write-Warning "jellyfin/library: duplicate library name '$($spec.name)' from user '$($spec.ownerUser)'; keeping first declaration from '$($mergedSpecs[$lowerName].ownerUser)'."
      continue
    }
    $mergedSpecs[$lowerName] = $spec
  }

  # 3. Define Invoke-JellyfinApi helper (same implementation as account sync).
  $authHeaderBase = 'MediaBrowser Client="nucleus-apply", DeviceId="windows-apply", Device="Windows", Version="1.0.0"'

  function Invoke-JellyfinApi {
    param(
      [Parameter(Mandatory)]
      [ValidateSet('GET', 'POST')]
      [string]$Method,

      [Parameter(Mandatory)]
      [string]$Path,

      [string]$Token,

      [AllowNull()]
      [object]$Body
    )

    $headers = @{ Authorization = $authHeaderBase }
    if (-not [string]::IsNullOrWhiteSpace($Token)) {
      $headers.Authorization = "$($headers.Authorization), Token=$Token"
    }

    $params = @{
      Method             = $Method
      Uri                = "$BaseUrl$Path"
      Headers            = $headers
      TimeoutSec         = 10
      SkipHttpErrorCheck = $true
    }

    if ($null -ne $Body) {
      $params.ContentType = 'application/json'
      $params.Body = ($Body | ConvertTo-Json -Depth 8 -Compress)
    }

    try {
      $response = Invoke-WebRequest @params
      $jsonBody = $null
      if (-not [string]::IsNullOrWhiteSpace($response.Content)) {
        try {
          $jsonBody = $response.Content | ConvertFrom-Json
        }
        catch {
          $jsonBody = $null
        }
      }
      return [PSCustomObject]@{
        StatusCode = [int]$response.StatusCode
        Body       = $jsonBody
      }
    }
    catch {
      return [PSCustomObject]@{
        StatusCode = 0
        Body       = $null
      }
    }
  }

  # 4. Wait up to 60s for Jellyfin API readiness.
  $serverReady = $false
  foreach ($second in 1..60) {
    $ping = Invoke-JellyfinApi -Method GET -Path '/System/Info/Public'
    if ($ping.StatusCode -eq 200) {
      $serverReady = $true
      break
    }
    Start-Sleep -Seconds 1
  }

  if (-not $serverReady) {
    Write-Warning "jellyfin/library: API at $BaseUrl is not reachable; skipping library convergence."
    return
  }

  # 5. Acquire admin token: try each resolved user's credentials, fall back to
  #    startup bootstrap.
  $adminToken = $null
  foreach ($cred in $authCreds) {
    $auth = Invoke-JellyfinApi -Method POST -Path '/Users/AuthenticateByName' -Body @{
      Username = $cred.username
      Pw       = $cred.password
    }
    if ($auth.StatusCode -ne 200 -or [string]::IsNullOrWhiteSpace([string]$auth.Body.AccessToken)) {
      continue
    }
    $token = [string]$auth.Body.AccessToken
    $me = Invoke-JellyfinApi -Method GET -Path '/Users/Me' -Token $token
    if ($me.StatusCode -eq 200 -and ($me.Body.Policy.IsAdministrator -eq $true)) {
      $adminToken = $token
      break
    }
  }

  if (-not $adminToken) {
    $bootstrapCred = $authCreds | Select-Object -First 1
    if ($bootstrapCred) {
      $startupUser = Invoke-JellyfinApi -Method POST -Path '/Startup/User' -Body @{
        Name     = $bootstrapCred.username
        Password = $bootstrapCred.password
      }
      if ($startupUser.StatusCode -eq 204) {
        [void](Invoke-JellyfinApi -Method POST -Path '/Startup/Complete')
      }

      foreach ($attempt in 1..15) {
        $retryAuth = Invoke-JellyfinApi -Method POST -Path '/Users/AuthenticateByName' -Body @{
          Username = $bootstrapCred.username
          Pw       = $bootstrapCred.password
        }
        if ($retryAuth.StatusCode -eq 200 -and -not [string]::IsNullOrWhiteSpace([string]$retryAuth.Body.AccessToken)) {
          $retryToken = [string]$retryAuth.Body.AccessToken
          $retryMe = Invoke-JellyfinApi -Method GET -Path '/Users/Me' -Token $retryToken
          if ($retryMe.StatusCode -eq 200 -and ($retryMe.Body.Policy.IsAdministrator -eq $true)) {
            $adminToken = $retryToken
            break
          }
        }
        Start-Sleep -Seconds 1
      }
    }
  }

  if (-not $adminToken) {
    Write-Warning 'jellyfin/library: no elevated account credentials available; skipping library convergence.'
    return
  }

  # 6. GET /Library/VirtualFolders — list existing.
  $existingFolders = Invoke-JellyfinApi -Method GET -Path '/Library/VirtualFolders' -Token $adminToken
  if ($existingFolders.StatusCode -ne 200) {
    Write-Warning 'jellyfin/library: failed to list virtual folders; skipping library convergence.'
    return
  }

  $existingByName = @{}
  foreach ($folder in @($existingFolders.Body | Where-Object { $_ })) {
    $folderName = [string]$folder.Name
    if (-not [string]::IsNullOrWhiteSpace($folderName)) {
      $existingByName[$folderName.ToLowerInvariant()] = $folder
    }
  }

  # 7. For each declared library: create if missing, update LibraryOptions if exists.
  foreach ($spec in $mergedSpecs.Values) {
    $lowerName = $spec.name.ToLowerInvariant()
    $existing = $existingByName[$lowerName]

    # Build LibraryOptions payload.
    $opts = $spec.options
    $imageOptions = @()
    if ($opts.imageOptions.Backdrop) {
      $imageOptions += @{
        Type     = "Backdrop"
        Limit    = [int]$opts.imageOptions.Backdrop.limit
        MinWidth = [int]$opts.imageOptions.Backdrop.minWidth
      }
    }
    if ($opts.imageOptions.Logo) {
      $imageOptions += @{
        Type  = "Logo"
        Limit = [int]$opts.imageOptions.Logo.limit
      }
    }
    if ($opts.imageOptions.Primary) {
      $imageOptions += @{
        Type  = "Primary"
        Limit = [int]$opts.imageOptions.Primary.limit
      }
    }

    $libraryOptions = @{
      Enabled                               = [bool]$opts.enabled
      EnableRealtimeMonitor                 = [bool]$opts.enableRealtimeMonitor
      EnableEmbeddedTitles                  = [bool]$opts.enableEmbeddedTitles
      EnableEmbeddedExtrasTitles            = [bool]$opts.enableEmbeddedExtrasTitles
      AllowEmbeddedSubtitles                = [string]$opts.allowEmbeddedSubtitles
      MetadataSavers                        = @()
      SaveLocalMetadata                     = [bool]$opts.saveLocalMetadata
      EnableChapterImageExtraction          = [bool]$opts.enableChapterImageExtraction
      ExtractChapterImagesDuringLibraryScan = [bool]$opts.extractChapterImagesDuringLibraryScan
      EnableTrickplayImageExtraction        = [bool]$opts.enableTrickplayImageExtraction
      ExtractTrickplayImagesDuringLibraryScan = [bool]$opts.extractTrickplayImagesDuringLibraryScan
      SaveTrickplayWithMedia                = [bool]$opts.saveTrickplayWithMedia
      TypeOptions                           = @(
        @{
          Type             = "MusicVideo"
          ImageFetchers    = @($opts.imageFetchers | Where-Object { $_ })
          ImageFetcherOrder = @($opts.imageFetchers | Where-Object { $_ })
          MetadataFetchers = @()
          ImageOptions     = $imageOptions
        }
      )
    }

    if (-not $existing) {
      # Create new library.
      $queryParams = "name=$([System.Uri]::EscapeDataString($spec.name))&collectionType=$([System.Uri]::EscapeDataString($spec.collectionType))"
      foreach ($path in $spec.paths) {
        $queryParams += "&paths=$([System.Uri]::EscapeDataString($path))"
      }
      $createResponse = Invoke-JellyfinApi -Method POST -Path "/Library/VirtualFolders?$queryParams" -Token $adminToken -Body @{
        LibraryOptions = $libraryOptions
        Paths          = [string[]]@($spec.paths | ForEach-Object { $_ })
        RefreshLibrary = $true
      }
      if ($createResponse.StatusCode -eq 204) {
        Write-Output "jellyfin/library: created library '$($spec.name)' ($($spec.collectionType))."
        $null = Invoke-JellyfinApi -Method POST -Path '/Library/Refresh' -Token $adminToken
      }
      else {
        Write-Warning "jellyfin/library: failed to create library '$($spec.name)' (HTTP $($createResponse.StatusCode))."
      }
    }
    else {
      # Update existing library options.
      $itemId = [string]$existing.ItemId
      if ([string]::IsNullOrWhiteSpace($itemId)) {
        $itemId = [string]$existing.Id
      }
      $updateResponse = Invoke-JellyfinApi -Method POST -Path '/Library/VirtualFolders/LibraryOptions' -Token $adminToken -Body @{
        Id             = $itemId
        LibraryOptions = $libraryOptions
      }
      if ($updateResponse.StatusCode -eq 204) {
        Write-Output "jellyfin/library: updated library options for '$($spec.name)'."
        $null = Invoke-JellyfinApi -Method POST -Path '/Library/Refresh' -Token $adminToken
      }
      else {
        Write-Warning "jellyfin/library: failed to update library options for '$($spec.name)' (HTTP $($updateResponse.StatusCode))."
      }
    }
  }
}
