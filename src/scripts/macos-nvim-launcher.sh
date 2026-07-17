    # Create a deterministic symlink at /etc/nucleus-bin/nvim so vscode-neovim
    # can find nvim (the extension doesn't expand ${""}{userHome} or ~).
    # Resolves the nvim path for the active console user at runtime.
    console_user="$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || echo "")"
    if [ -n "$console_user" ]; then
      _nvim_real="/etc/profiles/per-user/$console_user/bin/nvim"
      if [ -x "$_nvim_real" ]; then
        /bin/mkdir -p /etc/nucleus-bin
        /bin/ln -sfn "$_nvim_real" /etc/nucleus-bin/nvim
      fi
    fi
