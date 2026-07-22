#!/usr/bin/env bash
# Tracks the fingerprint of the managed personal SSH public key in
# ~/.config/nucleus/managed-ssh-keys and flushes the in-memory SSH agent
# when the fingerprint changes (i.e., the key was rotated in the SOPS secret).

set -euo pipefail


_ssh_pub_path="$1"
_ssh_keygen_bin="$2"
_ssh_add_bin="$3"

nucleus_config_dir="$HOME/.config/nucleus"
managed_ssh_manifest="$nucleus_config_dir/managed-ssh-keys"

if [ ! -f "$_ssh_pub_path" ]; then
  # Not a hard error: sops-nix reports its own failure if materialization
  # did not complete.  Warn and skip so this activation does not mask the
  # upstream sops-nix error with a different message.
  echo "secrets: managed SSH public key not found at '$_ssh_pub_path'; skipping fingerprint adoption." >&2
else
  # undoc-supp: SSH public key may not exist yet on first provision; ssh-keygen -lf exits 1 for missing/invalid keys.
  new_fingerprint="$("$_ssh_keygen_bin" -lf "$_ssh_pub_path" | /usr/bin/awk '{print $2}')" || true

  if [ -z "$new_fingerprint" ]; then
    echo "secrets: could not extract fingerprint from '$_ssh_pub_path'; skipping adoption." >&2
  else
    old_fingerprint=""
    if [ -f "$managed_ssh_manifest" ]; then
      old_fingerprint="$(cat "$managed_ssh_manifest")" || old_fingerprint=""
    fi

    if [ "$old_fingerprint" != "$new_fingerprint" ]; then
      # Flush in-memory SSH agent so stale cached key material is cleared.
      # The guard intentionally omits the `[ -n "$old_fingerprint" ]` check
      # so that on first provision (absent manifest, empty old_fingerprint)
      # any pre-placed key already loaded in the agent is also evicted.
      # AddKeysToAgent=yes in the SSH config re-loads the new key on the
      # next outbound SSH connection.
      echo "secrets: managed SSH key fingerprint changed ($old_fingerprint -> $new_fingerprint); flushing SSH agent." >&2
      # undoc-supp: ssh-add -D fails when no agent is running; benign since nothing needs flushing.
      "$_ssh_add_bin" -D 2>/dev/null || true
    fi

    mkdir -p "$nucleus_config_dir"
    printf '%s\n' "$new_fingerprint" > "$managed_ssh_manifest"
    # Restrict manifest to owner-read-only: SSH fingerprint data can be
    # used to correlate keys across systems; minimise unnecessary visibility.
    chmod 600 "$managed_ssh_manifest"
  fi
fi
