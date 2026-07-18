# LiteLLM wrapper PowerShell script.
# Written to disk by Sync-LiteLLMService.ps1 with tokens replaced by actual values.
$env:LITELLM_LOG = 'WARNING'
$env:OPENROUTER_API_KEY = if (Test-Path '__OPENROUTER_KEY_FILE__') { Get-Content '__OPENROUTER_KEY_FILE__' -Raw | ForEach-Object { $_.Trim() } } else { '' }
$env:OPENCODE_GO_API_KEY = if (Test-Path '__OPENCODE_GO_KEY_FILE__') { Get-Content '__OPENCODE_GO_KEY_FILE__' -Raw | ForEach-Object { $_.Trim() } } else { '' }
$env:OPENCODE_ZEN_API_KEY = if (Test-Path '__OPENCODE_ZEN_KEY_FILE__') { Get-Content '__OPENCODE_ZEN_KEY_FILE__' -Raw | ForEach-Object { $_.Trim() } } else { '' }
& '__LITELLM_BIN__' --config '__CONFIG_LINK__' --port __PORT__ --host '__HOST__' --drop_params *>> '__LOGFILE__'
