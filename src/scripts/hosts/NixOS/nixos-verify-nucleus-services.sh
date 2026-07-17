# Warn-only check that all managed services are running after activation.
# Failing to start a service should not block activation, but the warning
# surfaces issues for post-apply investigation.
if command -v nucleus-svc >/dev/null 2>&1; then
  if ! nucleus-svc verify; then
    echo "svc: some services are inactive (non-fatal; check journalctl for details)" >&2
  fi
fi
