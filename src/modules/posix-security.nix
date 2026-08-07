# Shared privilege-escalation hardening (sudo timeout).
{ ... }: {
  # Shorten sudo credential caching to reduce unattended escalation window.
  security.sudo.extraConfig = ''
    Defaults timestamp_timeout=5
    Defaults env_keep += "NUCLEUS_REPO_ROOT"
  '';
}
