<#
.SYNOPSIS
  Ensure the LiteLLM AI gateway proxy scheduled task is converged.

.DESCRIPTION
  Registers (or removes) a per-user scheduled task that starts the LiteLLM
  proxy on 127.0.0.1:4000.  LiteLLM is installed via `uv tool install` by
  Invoke-UvSetup; the scheduled task ensures it survives user logoff/reboot.
  The config file is sourced from the repository share.

.PARAMETER RepoRoot
  Absolute repository root path used to resolve litellm-config.yml.

.PARAMETER Enabled
  Whether the LiteLLM task should exist. When false, the managed task is
  removed if present.
#>
function Sync-LiteLLMScheduledTask {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,
    [Parameter(Mandatory)]
    [bool]$Enabled
  )

  $ErrorActionPreference = "Stop"
  $taskName = "NucleusLiteLLM"

  if (-not $Enabled) {
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -ne $existingTask) {
      Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
      Write-Output "litellm: removed scheduled task '$taskName' (disabled)"
    }
    return
  }

  $resolvedRepoRoot = (Resolve-Path -Path $RepoRoot).Path
  $configPath = Join-Path -Path $resolvedRepoRoot -ChildPath "src\modules\ai\litellm-config.yml"
  if (-not (Test-Path -Path $configPath -PathType Leaf)) {
    throw "litellm: config not found at '$configPath'."
  }

  # Find the litellm binary installed by uv.  uv tool install places binaries
  # in ~\.local\bin by default.
  $litellmBin = Join-Path -Path $HOME -ChildPath ".local\bin\litellm.exe"
  if (-not (Test-Path -Path $litellmBin -PathType Leaf)) {
    # Fall back to PATH resolution (may work if user has added ~\.local\bin).
    $litellmCmd = Get-Command -Name "litellm" -ErrorAction SilentlyContinue
    if ($null -eq $litellmCmd) {
      Write-Output "litellm: binary not found; ensure Invoke-UvSetup has installed 'litellm[proxy]'"
      return
    }
    $litellmBin = $litellmCmd.Source
  }

  $userId = if ([string]::IsNullOrWhiteSpace($env:USERDOMAIN)) {
    $env:USERNAME
  } else {
    "$($env:USERDOMAIN)\$($env:USERNAME)"
  }

  # Secrets are read from the SOPS-decrypted system secrets directory.
  $decryptedDir = Join-Path -Path $env:USERPROFILE -ChildPath ".config\nucleus\secrets"
  $openrouterKeyFile = Join-Path -Path $decryptedDir -ChildPath "ai_openrouter_api_key"

  $actionCommand = @"
`$env:OPENROUTER_API_KEY = if (Test-Path '$openrouterKeyFile') { Get-Content '$openrouterKeyFile' -Raw | ForEach-Object { `$_.Trim() } } else { '' }
& "$litellmBin" --config "$configPath" --port 4000 --host 127.0.0.1 --drop_params
"@

  $action = New-ScheduledTaskAction -Execute "pwsh.exe" -Argument "-NoLogo -ExecutionPolicy Bypass -Command `"$actionCommand`""

  # Use the same trigger pattern as the gc-weekly task: run at user logon and
  # restart every hour if stopped (liteLLM is lightweight).
  $trigger = New-ScheduledTaskTrigger -AtStartup
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
  $principal = New-ScheduledTaskPrincipal -UserId $userId -RunLevel Limited

  $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if ($null -ne $existingTask) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
  }

  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force
  Write-Output "litellm: registered scheduled task '$taskName'"
}
