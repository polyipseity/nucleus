<#
.SYNOPSIS
  Ensure the LiteLLM AI gateway proxy scheduled task is converged.

.DESCRIPTION
  Registers (or removes) a per-user scheduled task that starts the LiteLLM
  proxy on 127.0.0.1:4000.  LiteLLM is installed via `uv tool install` by
  Invoke-UvSetup; the scheduled task ensures it survives user logoff/reboot.
  The config is read from ~\.config\nucleus\litellm-config.yml, a symlink
  created by apply.ps1 that follows the live source file.

.PARAMETER Enabled
  Whether the LiteLLM task should exist. When false, the managed task is
  removed if present.

.EXAMPLE
  Sync-LiteLLMScheduledTask -Enabled:$true

.EXAMPLE
  Sync-LiteLLMScheduledTask -Enabled:$false

.NOTES
  Environment variables:
    (none)    No environment variables used.

  Exit codes:
    0 on success; 1 on error.
#>
function Sync-LiteLLMScheduledTask {
  [CmdletBinding()]
  param(
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

  $configPath = Join-Path -Path $env:USERPROFILE -ChildPath ".config\nucleus\litellm-config.yml"
  if (-not (Test-Path -Path $configPath -PathType Leaf)) {
    throw "litellm: config symlink not found at '$configPath'. Run apply.ps1 first."
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

  $logDir = Join-Path -Path $env:LOCALAPPDATA -ChildPath "nucleus\logs"
  $logFile = Join-Path -Path $logDir -ChildPath "litellm.log"

  # Secrets are read from the SOPS-decrypted system secrets directory.
  $decryptedDir = Join-Path -Path $env:USERPROFILE -ChildPath ".config\nucleus\secrets"
  $openrouterKeyFile = Join-Path -Path $decryptedDir -ChildPath "ai_openrouter_api_key"
  $opencodeKeyFile = Join-Path -Path $decryptedDir -ChildPath "ai_opencode_api_key"

  # Ensure the log directory exists.
  $null = New-Item -Path $logDir -ItemType Directory -Force

  $actionCommand = @"
`$env:LITELLM_LOG = 'WARNING'
`$env:OPENROUTER_API_KEY = if (Test-Path '$openrouterKeyFile') { Get-Content '$openrouterKeyFile' -Raw | ForEach-Object { `$_.Trim() } } else { '' }
`$env:OPENCODE_GO_API_KEY = if (Test-Path '$opencodeKeyFile') { Get-Content '$opencodeKeyFile' -Raw | ForEach-Object { `$_.Trim() } } else { '' }
& "$litellmBin" --config "$configPath" --port 4000 --host 127.0.0.1 --drop_params *>> "$logFile"
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
