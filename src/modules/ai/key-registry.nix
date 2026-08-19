# key-registry.nix — SOPS key → env var mapping for AI API keys.
#
# Pure data: maps each SOPS secret name to the environment variable name
# that the daemon scripts export before starting litellm.  Adding a new
# provider = one SOPS key in system.yml + one env var here + one model_list
# entry in litellm-config.yml.
#
# Consumers: litellm-daemon.sh (POSIX), Sync-LiteLLMService.ps1 (Windows).
{
  ai_openrouter_api_key = "OPENROUTER_API_KEY";
  ai_opencode_zen_api_key = "OPENCODE_ZEN_API_KEY";
  ai_opencode_go_api_key = "OPENCODE_GO_API_KEY";
  ai_command_code_api_key = "COMMAND_CODE_API_KEY";
}
