# LiteLLM wrapper PowerShell script.
# Written to disk by Sync-LiteLLMService.ps1 with tokens replaced by actual values.
$LITELLM_LOG = 'WARNING'
$secretsDir = Join-Path -Path $env:ProgramData -ChildPath 'nucleus\secrets'
# __KEY_SPECS__ is replaced by Sync-LiteLLMService.ps1 with a JSON array of
# { file, env } objects — one per available AI API key.
$keySpecs = '__KEY_SPECS__' | ConvertFrom-Json
foreach ($spec in $keySpecs) {
  $keyPath = Join-Path -Path $secretsDir -ChildPath $spec.file
  if (Test-Path -LiteralPath $keyPath) {
    $raw = (Get-Content -LiteralPath $keyPath -Raw).Trim()
    [System.Environment]::SetEnvironmentVariable($spec.env, $raw, 'Process')
  }
}
[System.Environment]::SetEnvironmentVariable('LITELLM_LOG', $LITELLM_LOG, 'Process')
# Redis env vars for LiteLLM coordination + response cache.
[System.Environment]::SetEnvironmentVariable('REDIS_HOST', '__REDIS_HOST__', 'Process')
[System.Environment]::SetEnvironmentVariable('REDIS_PORT', '__REDIS_PORT__', 'Process')
# WHY: stdout and stderr go to separate files. logging.capture selects WHICH streams are
# captured, never the destination shape; the house default is the stdout.log/stderr.log pair.
& '__LITELLM_BIN__' --config '__CONFIG_LINK__' --port __PORT__ --host '__HOST__' --drop_params 1>> '__STDOUT_LOG__' 2>> '__STDERR_LOG__'
