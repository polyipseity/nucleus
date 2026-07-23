& {
  if (Test-Path -Path $PROFILE.CurrentUserAllHosts -PathType Leaf) { . $PROFILE.CurrentUserAllHosts }
  if (Test-Path -Path $PROFILE.CurrentUserCurrentHost -PathType Leaf) { . $PROFILE.CurrentUserCurrentHost }

  # check-suppress:suppression_doc: probe — command may not be installed; $null check handles absence.
  $nucleusCommand = Get-Command -Name "nucleus-replica-sync" -ErrorAction SilentlyContinue
  if ($null -ne $nucleusCommand) {
    nucleus-replica-sync
    exit $LASTEXITCODE
  }

  & '__SCRIPT_PATH__'
  exit $LASTEXITCODE
}
