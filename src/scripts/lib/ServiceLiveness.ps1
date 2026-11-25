#Requires -Version 7.0
# ServiceLiveness.ps1 - liveness probes for nucleus service endpoints.
#
# Dot-sourceable. Provides Invoke-ServiceLivenessProbe.
#
# Endpoint input: hashtable or PSCustomObject with keys/props:
#   host (string), port (int), protocol (http|https|tcp), optional health:
#     path (string, required if health present), optional expect: {status, statusClass, bodyJsonSubset},
#     optional timeoutSeconds (default 5).
#
# Returns PSCustomObject: @{ Status = 'live'|'dead'|'unknown'; Reason = string }

function Get-SlProp {
  param(
    [Parameter(Mandatory)][object]$InputObject,
    [Parameter(Mandatory)][string]$Name,
    [object]$Default = $null
  )
  if ($null -eq $InputObject) { return $Default }
  if ($InputObject -is [System.Collections.IDictionary]) {
    if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
    return $Default
  }
  $prop = $InputObject.PSObject.Properties[$Name]
  if ($null -ne $prop) { return $prop.Value }
  return $Default
}

function Test-SlJsonSubset {
  param(
    [Parameter(Mandatory)]$Subset,
    [Parameter(Mandatory)]$Actual
  )
  if ($null -eq $Subset) { return $true }
  # If subset is a hashtable/dictionary
  if ($Subset -is [System.Collections.IDictionary]) {
    if ($null -eq $Actual -or ($Actual -isnot [System.Collections.IDictionary] -and $Actual.GetType().Name -ne 'PSCustomObject' -and $Actual.GetType().Name -ne 'OrderedDictionary')) {
      # Try to treat PSCustomObject as object
    }
    foreach ($key in $Subset.Keys) {
      $subVal = $Subset[$key]
      $actVal = $null
      if ($Actual -is [System.Collections.IDictionary]) {
        if (-not $Actual.Contains($key)) { return $false }
        $actVal = $Actual[$key]
      } else {
        # PSCustomObject
        $prop = $Actual.PSObject.Properties[$key]
        if ($null -eq $prop) { return $false }
        $actVal = $prop.Value
      }
      if (-not (Test-SlJsonSubset -Subset $subVal -Actual $actVal)) { return $false }
    }
    return $true
  }
  # If subset is a PSCustomObject (from ConvertFrom-Json)
  if ($Subset.GetType().Name -eq 'PSCustomObject' -or $Subset.GetType().FullName -like 'System.Management.Automation.PSCustomObject*') {
    if ($null -eq $Actual) { return $false }
    foreach ($prop in $Subset.PSObject.Properties) {
      $key = $prop.Name
      $subVal = $prop.Value
      $actVal = $null
      if ($Actual -is [System.Collections.IDictionary]) {
        if (-not $Actual.Contains($key)) { return $false }
        $actVal = $Actual[$key]
      } else {
        $aProp = $Actual.PSObject.Properties[$key]
        if ($null -eq $aProp) { return $false }
        $actVal = $aProp.Value
      }
      if (-not (Test-SlJsonSubset -Subset $subVal -Actual $actVal)) { return $false }
    }
    return $true
  }
  # Arrays
  if ($Subset -is [System.Collections.IEnumerable] -and $Subset -isnot [string]) {
    if ($Actual -isnot [System.Collections.IEnumerable] -or $Actual -is [string]) { return $false }
    $subList = @($Subset)
    $actList = @($Actual)
    if ($subList.Count -ne $actList.Count) {
      # For subset semantics on arrays, maybe not exact; but keep simple: try to match as deep equal for now
      return $false
    }
    for ($i = 0; $i -lt $subList.Count; $i++) {
      if (-not (Test-SlJsonSubset -Subset $subList[$i] -Actual $actList[$i])) { return $false }
    }
    return $true
  }
  # Scalar comparison
  return ($Subset -eq $Actual)
}

function Close-SlClient {
  # check-suppress:SuppressMessageAttribute: PSAvoidUsingEmptyCatchBlock -- a probe must not fail because closing its own socket did
  [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '')]
  param(
    [Parameter(Mandatory)][object]$Client
  )
  try { $Client.Close() } catch {
    # WHY: the probe's verdict is already decided at this point; a close failure cannot change it.
  }
}

function Invoke-ServiceLivenessProbe {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object]$Endpoint
  )

  $protocol = Get-SlProp -InputObject $Endpoint -Name 'protocol'
  $endpointHost = Get-SlProp -InputObject $Endpoint -Name 'host'
  $port = Get-SlProp -InputObject $Endpoint -Name 'port'

  if ([string]::IsNullOrWhiteSpace([string]$protocol) -or [string]::IsNullOrWhiteSpace([string]$endpointHost) -or $null -eq $port) {
    return [pscustomobject]@{ Status = 'unknown'; Reason = 'unknown:missing-fields' }
  }

  $protocolLc = ([string]$protocol).ToLowerInvariant()
  $hostStr = [string]$endpointHost
  $portInt = 0
  if (-not [int]::TryParse([string]$port, [ref]$portInt)) {
    return [pscustomobject]@{ Status = 'unknown'; Reason = 'unknown:invalid-port' }
  }

  # Normalize host
  $hostProbe = $hostStr
  if ($hostStr -eq '0.0.0.0' -or $hostStr -eq '::') {
    $hostProbe = '127.0.0.1'
  }

  $health = Get-SlProp -InputObject $Endpoint -Name 'health'
  $timeoutSec = 5
  if ($null -ne $health) {
    $hsTimeout = Get-SlProp -InputObject $health -Name 'timeoutSeconds'
    if ($null -ne $hsTimeout) {
      $parsedTimeout = 0
      if ([int]::TryParse([string]$hsTimeout, [ref]$parsedTimeout) -and $parsedTimeout -ge 1) {
        $timeoutSec = $parsedTimeout
      }
    }
  }

  if ($protocolLc -eq 'tcp') {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
      $task = $client.ConnectAsync($hostProbe, $portInt)
      $completed = $task.Wait([TimeSpan]::FromSeconds($timeoutSec))
      if (-not $completed) {
        Close-SlClient -Client $client
        return [pscustomobject]@{ Status = 'unknown'; Reason = 'unknown:timeout' }
      }
      if ($task.IsFaulted) {
        Close-SlClient -Client $client
        return [pscustomobject]@{ Status = 'dead'; Reason = 'dead:connect-failed' }
      }
      Close-SlClient -Client $client
      return [pscustomobject]@{ Status = 'live'; Reason = 'live' }
    } catch {
      Close-SlClient -Client $client
      return [pscustomobject]@{ Status = 'dead'; Reason = 'dead:connect-failed' }
    }
  }

  if ($protocolLc -eq 'http' -or $protocolLc -eq 'https') {
    if ($null -eq $health) {
      # Transport-only: TCP connect
      $client = New-Object System.Net.Sockets.TcpClient
      try {
        $task = $client.ConnectAsync($hostProbe, $portInt)
        $completed = $task.Wait([TimeSpan]::FromSeconds($timeoutSec))
        if (-not $completed) {
          Close-SlClient -Client $client
          return [pscustomobject]@{ Status = 'unknown'; Reason = 'unknown:timeout' }
        }
        if ($task.IsFaulted) {
          Close-SlClient -Client $client
          return [pscustomobject]@{ Status = 'dead'; Reason = 'dead:connect-failed' }
        }
        Close-SlClient -Client $client
        return [pscustomobject]@{ Status = 'live'; Reason = 'live' }
      } catch {
        Close-SlClient -Client $client
        return [pscustomobject]@{ Status = 'dead'; Reason = 'dead:connect-failed' }
      }
    }

    $healthPath = Get-SlProp -InputObject $health -Name 'path'
    if ([string]::IsNullOrWhiteSpace([string]$healthPath)) {
      return [pscustomobject]@{ Status = 'unknown'; Reason = 'unknown:missing-health-path' }
    }
    $url = "${protocolLc}://${hostProbe}:$portInt$([string]$healthPath)"

    $expect = Get-SlProp -InputObject $health -Name 'expect'
    $expectStatus = $null
    $expectStatusClass = $null
    $bodyJsonSubset = $null
    if ($null -ne $expect) {
      $expectStatus = Get-SlProp -InputObject $expect -Name 'status'
      $expectStatusClass = Get-SlProp -InputObject $expect -Name 'statusClass'
      $bodyJsonSubset = Get-SlProp -InputObject $expect -Name 'bodyJsonSubset'
    }

    try {
      $resp = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec $timeoutSec -SkipHttpErrorCheck -UseBasicParsing -ErrorAction Stop
    } catch {
      $msg = $_.Exception.Message
      # Timeout detection is heuristic; prefer unknown for timeouts
      if ($msg -match 'timed out|timeout' -or $_.Exception.GetType().Name -match 'Timeout') {
        return [pscustomobject]@{ Status = 'unknown'; Reason = 'unknown:timeout' }
      }
      return [pscustomobject]@{ Status = 'unknown'; Reason = 'unknown:transport-failure' }
    }

    $statusCode = [int]$resp.StatusCode

    # Check expectations
    if ($null -ne $expectStatus -and $expectStatus -ne '') {
      $esInt = 0
      try { $esInt = [int]$expectStatus } catch { $esInt = -1 }
      if ($statusCode -ne $esInt) {
        return [pscustomobject]@{ Status = 'dead'; Reason = "dead:status=$statusCode" }
      }
    } elseif ($null -ne $expectStatusClass -and $expectStatusClass -ne '') {
      $cls = [string]$expectStatusClass
      $ok = $false
      if ($cls -eq '2xx') { $ok = ($statusCode -ge 200 -and $statusCode -le 299) }
      elseif ($cls -eq '3xx') { $ok = ($statusCode -ge 300 -and $statusCode -le 399) }
      elseif ($cls -eq '4xx') { $ok = ($statusCode -ge 400 -and $statusCode -le 499) }
      elseif ($cls -eq '5xx') { $ok = ($statusCode -ge 500 -and $statusCode -le 599) }
      if (-not $ok) {
        return [pscustomobject]@{ Status = 'dead'; Reason = "dead:status=$statusCode" }
      }
    } else {
      # Default expect 2xx
      if ($statusCode -lt 200 -or $statusCode -gt 299) {
        return [pscustomobject]@{ Status = 'dead'; Reason = "dead:status=$statusCode" }
      }
    }

    # Body subset check
    if ($null -ne $bodyJsonSubset) {
      try {
        $actualJson = $resp.Content | ConvertFrom-Json -ErrorAction Stop
        $subOk = Test-SlJsonSubset -Subset $bodyJsonSubset -Actual $actualJson
        if (-not $subOk) {
          return [pscustomobject]@{ Status = 'dead'; Reason = 'dead:body-mismatch' }
        }
      } catch {
        return [pscustomobject]@{ Status = 'dead'; Reason = 'dead:body-mismatch' }
      }
    }

    return [pscustomobject]@{ Status = 'live'; Reason = 'live' }
  }

  return [pscustomobject]@{ Status = 'unknown'; Reason = 'unknown:unsupported-protocol' }
}
