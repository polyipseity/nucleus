# Sync-JellyfinAccount.ps1 — Converge Jellyfin user accounts from per-user SOPS secrets.
#
# Applies the users.json jellyfin.accounts declarations against the host-shared
# Jellyfin server via its HTTP API. Each account declaration references secret
# keys inside src/secrets/users-<username>.yml so plaintext credentials never
# live in users.json.
#
# API behavior source (upstream Jellyfin):
# - POST /Users/AuthenticateByName
# - POST /Users/New (RequiresElevation)
# - POST /Users/Password?userId=<id>
# - Startup bootstrap via /Startup/User + /Startup/Complete when needed
# Source: https://raw.githubusercontent.com/jellyfin/jellyfin/0beb07c40756aca5ab6a6ba4f8494bc5147e3c2b/Jellyfin.Api/Controllers/UserController.cs
# Source: https://raw.githubusercontent.com/jellyfin/jellyfin/0beb07c40756aca5ab6a6ba4f8494bc5147e3c2b/Jellyfin.Api/Controllers/StartupController.cs

function Sync-JellyfinAccount {
  <#
  .SYNOPSIS
    Converges Jellyfin accounts declared in users.json.

  .DESCRIPTION
    Reads per-user jellyfin.accounts declarations from the loaded Windows user
    registry records, resolves username/password values from each user's
    src\secrets\users-<username>.yml SOPS file, and applies those accounts to
    the host-shared Jellyfin server.

    The function is idempotent:
      - Existing users are not recreated.
      - Passwords are changed only when current credentials fail login.

    On first-time setup (startup wizard not completed), the function attempts to
    initialize startup credentials with the first declared account and then
    completes startup before continuing normal provisioning.

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
    Sync-JellyfinAccount -RepoRoot 'C:\Users\admin\nucleus' -UserRecords $records `
      -GpgExe 'C:\Program Files\GnuPG\bin\gpg.exe' `
      -HostKeyPath 'C:\ProgramData\ssh\ssh_host_ed25519_key' `
      -PrimarySshKeyPath 'C:\Users\admin\.ssh\ssh_personal_admin' `
      -SopsExe 'C:\Users\admin\AppData\Local\Microsoft\WinGet\Packages\SecretsOPerationS.SOPS_...\sops.exe'
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

  $accountSpecs = @()
  foreach ($userRecord in @($UserRecords)) {
    $accounts = @($userRecord.jellyfin.accounts | Where-Object { $_ })
    if ($accounts.Count -eq 0) {
      continue
    }

    $secretFile = Join-Path $RepoRoot "src\secrets\users-$($userRecord.name).yml"
    if (-not (Test-Path -LiteralPath $secretFile -PathType Leaf)) {
      Write-Warning "jellyfin: users-$($userRecord.name).yml not found; skipping account declarations for this user."
      continue
    }

    try {
      $secrets = Get-Secret -FilePath $secretFile -GpgExe $GpgExe -HostKeyPath $HostKeyPath -PrimarySshKeyPath $PrimarySshKeyPath -SopsExe $SopsExe
    }
    catch {
      Write-Warning "jellyfin: failed to decrypt $secretFile; skipping account declarations for $($userRecord.name): $($_.Exception.Message)"
      continue
    }

    foreach ($account in $accounts) {
      $usernameKey = [string]$account.usernameSecretKey
      $passwordKey = [string]$account.passwordSecretKey
      if ([string]::IsNullOrWhiteSpace($usernameKey) -or [string]::IsNullOrWhiteSpace($passwordKey)) {
        Write-Warning "jellyfin: account '$($account.id)' for user '$($userRecord.name)' is missing usernameSecretKey/passwordSecretKey; skipping."
        continue
      }

      $resolvedUsername = [string]$secrets.$usernameKey
      $resolvedPassword = [string]$secrets.$passwordKey
      if ([string]::IsNullOrWhiteSpace($resolvedUsername) -or [string]::IsNullOrWhiteSpace($resolvedPassword)) {
        Write-Warning "jellyfin: account '$($account.id)' for user '$($userRecord.name)' has missing secret values; skipping."
        continue
      }

      $accountSpecs += [PSCustomObject]@{
        ownerUser = $userRecord.name
        id = [string]$account.id
        username = $resolvedUsername
        password = $resolvedPassword
        isAdmin = if ($null -eq $account.isAdmin) { $false } else { [bool]$account.isAdmin }
      }
    }
  }

  if ($accountSpecs.Count -eq 0) {
    Write-Verbose 'jellyfin: no accounts declared; skipping.'
    return
  }

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
      Method = $Method
      Uri = "$BaseUrl$Path"
      Headers = $headers
      TimeoutSec = 10
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
        Body = $jsonBody
      }
    }
    catch {
      return [PSCustomObject]@{
        StatusCode = 0
        Body = $null
      }
    }
  }

  # Wait briefly for Jellyfin API readiness; skip without failing apply when the
  # host has not enabled Jellyfin on this platform yet.
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
    Write-Warning "jellyfin: API at $BaseUrl is not reachable; skipping account convergence."
    return
  }

  # Acquire an elevated token from any configured account.
  $adminToken = $null
  foreach ($spec in $accountSpecs) {
    $auth = Invoke-JellyfinApi -Method POST -Path '/Users/AuthenticateByName' -Body @{
      Username = $spec.username
      Pw = $spec.password
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
    # First-time bootstrap path: configure startup user with the first declared
    # account if startup wizard is still open.
    $bootstrap = $accountSpecs | Select-Object -First 1
    $startupUser = Invoke-JellyfinApi -Method POST -Path '/Startup/User' -Body @{
      Name = $bootstrap.username
      Password = $bootstrap.password
    }
    if ($startupUser.StatusCode -eq 204) {
      [void](Invoke-JellyfinApi -Method POST -Path '/Startup/Complete')
    }

    foreach ($attempt in 1..15) {
      $retryAuth = Invoke-JellyfinApi -Method POST -Path '/Users/AuthenticateByName' -Body @{
        Username = $bootstrap.username
        Pw = $bootstrap.password
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

  if (-not $adminToken) {
    Write-Warning 'jellyfin: no elevated account credentials available; skipping user convergence.'
    return
  }

  foreach ($spec in $accountSpecs) {
    $usersResponse = Invoke-JellyfinApi -Method GET -Path '/Users' -Token $adminToken
    if ($usersResponse.StatusCode -ne 200) {
      Write-Warning 'jellyfin: failed to list users; stopping Jellyfin account convergence.'
      return
    }

    $matchingUser = @($usersResponse.Body | Where-Object { $_.Name -eq $spec.username }) | Select-Object -First 1
    if (-not $matchingUser) {
      $createResponse = Invoke-JellyfinApi -Method POST -Path '/Users/New' -Token $adminToken -Body @{
        Name = $spec.username
        Password = $spec.password
      }
      if ($createResponse.StatusCode -eq 200) {
        Write-Output "jellyfin: created account '$($spec.username)'."
        $matchingUser = $createResponse.Body
        if (-not $matchingUser -or [string]::IsNullOrWhiteSpace([string]$matchingUser.Id)) {
          Write-Warning "jellyfin: created account '$($spec.username)' but failed to resolve user id for policy convergence."
          continue
        }
      }
      else {
        Write-Warning "jellyfin: failed to create account '$($spec.username)' (HTTP $($createResponse.StatusCode))."
        continue
      }
    }

    $userDetail = Invoke-JellyfinApi -Method GET -Path "/Users/$($matchingUser.Id)" -Token $adminToken
    if ($userDetail.StatusCode -ne 200 -or -not $userDetail.Body) {
      Write-Warning "jellyfin: failed to query account details for '$($spec.username)' (HTTP $($userDetail.StatusCode))."
      continue
    }

    $currentPolicy = $userDetail.Body.Policy
    if ($null -eq $currentPolicy) {
      Write-Warning "jellyfin: missing policy payload for '$($spec.username)'; skipping admin policy convergence."
      continue
    }

    $currentIsAdmin = if ($null -eq $currentPolicy.IsAdministrator) { $false } else { [bool]$currentPolicy.IsAdministrator }
    if ($currentIsAdmin -ne [bool]$spec.isAdmin) {
      $policyBody = $currentPolicy | ConvertTo-Json -Depth 16 -Compress | ConvertFrom-Json
      $policyBody.IsAdministrator = [bool]$spec.isAdmin
      $policyUpdate = Invoke-JellyfinApi -Method POST -Path "/Users/$($matchingUser.Id)/Policy" -Token $adminToken -Body $policyBody
      if ($policyUpdate.StatusCode -eq 204) {
        Write-Output "jellyfin: updated admin policy for account '$($spec.username)' to $([bool]$spec.isAdmin)."
      }
      else {
        Write-Warning "jellyfin: failed to update admin policy for '$($spec.username)' (HTTP $($policyUpdate.StatusCode))."
      }
    }

    # Idempotency: keep existing password when current credentials still work.
    $canLogin = Invoke-JellyfinApi -Method POST -Path '/Users/AuthenticateByName' -Body @{
      Username = $spec.username
      Pw = $spec.password
    }
    if ($canLogin.StatusCode -eq 200) {
      Write-Verbose "jellyfin: account '$($spec.username)' already converged."
      continue
    }

    $passwordUpdate = Invoke-JellyfinApi -Method POST -Path "/Users/Password?userId=$($matchingUser.Id)" -Token $adminToken -Body @{
      ResetPassword = $false
      NewPw = $spec.password
    }

    if ($passwordUpdate.StatusCode -eq 204) {
      Write-Output "jellyfin: updated password for account '$($spec.username)'."
    }
    else {
      Write-Warning "jellyfin: failed to update password for '$($spec.username)' (HTTP $($passwordUpdate.StatusCode))."
    }
  }
}
