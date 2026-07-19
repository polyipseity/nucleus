# LiteLLM AI gateway daemon for macOS.
# Polls for SOPS-decrypted API key files at boot (5m timeout, 5s between
# attempts) to handle the race with sops-install-secrets on launchd startup.
# API key paths, binary, and config provided via Nix substitution.

# Boot-time race condition: sops-install-secrets may not have decrypted API keys
# to /run/secrets/ yet.  Poll for each secret file with a 5-minute timeout (60
# attempts, 5s apart).  This is preferred over launchd WatchPaths which has no
# timeout and can wedge boot indefinitely if the path is never created.
_wait_for_keyfile() {
  _path="$1"
  _timeout=60
  while [ ! -f "$_path" ] && [ "$_timeout" -gt 0 ]; do
    echo "litellm-daemon: waiting for $_path ..." >&2
    sleep 5
    _timeout=$((_timeout - 1))
  done
  if [ -f "$_path" ]; then
    cat "$_path"
    return 0
  else
    echo "litellm-daemon: WARNING $_path not found after 5m, continuing without it" >&2
    return 1
  fi
}

_keyfile_oru="__OPENROUTER_API_KEY_PATH__"
if _value="$(_wait_for_keyfile "$_keyfile_oru")"; then
  export OPENROUTER_API_KEY="$_value"
fi

_keyfile_oc_go="__OPENCODE_GO_API_KEY_PATH__"
if _value="$(_wait_for_keyfile "$_keyfile_oc_go")"; then
  export OPENCODE_GO_API_KEY="$_value"
fi

_keyfile_oc_zen="__OPENCODE_ZEN_API_KEY_PATH__"
if _value="$(_wait_for_keyfile "$_keyfile_oc_zen")"; then
  export OPENCODE_ZEN_API_KEY="$_value"
fi

exec __LITELLM_BIN__ \
  --config __LITELLM_CONFIG__ \
  --port 4000 \
  --host 127.0.0.1 \
  --drop_params
