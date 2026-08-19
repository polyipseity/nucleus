# key-registry.nix — Provider metadata for all AI API key types.
#
# Pure data: maps each SOPS key name to its provider attributes (env var,
# model, API base URL, routing order, token limits).  Adding a new provider
# = adding one entry here.  No other file needs provider-specific code.
#
# Consumers: litellm-config.nix (POSIX config generation),
#            Sync-LiteLLMService.ps1 (Windows config generation via
#            key-registry.json mirror), sops.nix (secret declarations).
{
  # ── OpenRouter ────────────────────────────────────────────────────────
  ai_openrouter_api_key = {
    envVar = "OPENROUTER_API_KEY";
    model = "openrouter/xiaomi/mimo-v2.5";
    apiBase = null; # null = OpenRouter default
    order = 3;
    reasoningEffort = "high";
    maxInputTokens = 128000;
    maxOutputTokens = 8192;
  };

  # ── OpenCode Zen (free tier) ──────────────────────────────────────────
  ai_opencode_zen_api_key = {
    envVar = "OPENCODE_ZEN_API_KEY";
    model = "openai/mimo-v2.5-free";
    apiBase = "https://opencode.ai/zen/v1";
    order = 1;
    reasoningEffort = "high";
    maxInputTokens = 128000;
    maxOutputTokens = 8192;
  };

  # ── OpenCode Go (paid tier) ──────────────────────────────────────────
  ai_opencode_go_api_key = {
    envVar = "OPENCODE_GO_API_KEY";
    model = "openai/mimo-v2.5";
    apiBase = "https://opencode.ai/zen/go/v1";
    order = 2;
    reasoningEffort = "high";
    maxInputTokens = 128000;
    maxOutputTokens = 8192;
  };

  # ── CommandCode ──────────────────────────────────────────────────────
  ai_command_code_api_key = {
    envVar = "COMMAND_CODE_API_KEY";
    model = "openai/tencent/hy3-paid";
    apiBase = "https://api.commandcode.ai/provider/v1";
    order = 2;
    reasoningEffort = "high";
    maxInputTokens = 128000;
    maxOutputTokens = 8192;
  };
}
