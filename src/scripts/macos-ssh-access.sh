    # Allow all users to connect via SSH by removing the macOS access-control
    # group. When com.apple.access_ssh does not exist, sshd allows any user
    # (subject to sshd_config AllowUsers/AllowGroups).
    # See: System Settings → General → Sharing → Remote Login → (i) → "Allow
    # access for: All Users"
    if /usr/sbin/dseditgroup -o delete -q com.apple.access_ssh 2>/dev/null; then
      echo "ssh: removed com.apple.access_ssh group; all users can now connect via SSH."
    else
      echo "ssh: com.apple.access_ssh group does not exist (already allowing all users)." >&2
    fi
