# LiteLLM AI gateway wrapper for NixOS.
# Reads SOPS-decrypted API key files (simple read, no polling) and starts
# litellm.  systemd restarts the service quickly if the files aren't ready,
# so no polling loop is needed (unlike the macOS launchd variant).
# API key paths, binary, and config provided via Nix substitution.
_keyfile_oru="__OPENROUTER_API_KEY_PATH__"
if [ -f "$_keyfile_oru" ]; then
  export OPENROUTER_API_KEY="$(cat "$_keyfile_oru")"
fi
_keyfile_oc_go="__OPENCODE_GO_API_KEY_PATH__"
if [ -f "$_keyfile_oc_go" ]; then
  export OPENCODE_GO_API_KEY="$(cat "$_keyfile_oc_go")"
fi
_keyfile_oc_zen="__OPENCODE_ZEN_API_KEY_PATH__"
if [ -f "$_keyfile_oc_zen" ]; then
  export OPENCODE_ZEN_API_KEY="$(cat "$_keyfile_oc_zen")"
fi
exec __LITELLM_BIN__ \
  --config __LITELLM_CONFIG__ \
  --port 4000 \
  --host 127.0.0.1 \
  --drop_params
