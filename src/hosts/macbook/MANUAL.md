# macbook manual steps

- BetterDisplay: grant Accessibility + Screen Recording in System Settings > Privacy & Security.
- Battery: open battery.app once and complete setup so `/usr/local/bin/battery` is installed.
- Chrome Remote Desktop: visit <https://remotedesktop.google.com/access> to name this Mac and set a PIN.
- Chrome Remote Desktop: grant Screen Recording + Accessibility to `ChromeRemoteDesktopHost`.
- Finder context menu: "Open in Terminal" and "Open in iTerm" should appear on both files/folders and empty space right-click after activation. If missing, restart Finder with `killall Finder`.
- Copy Path in Finder: available via right-click context menu; select a file/folder, right-click, and choose "Copy Path" to copy the full POSIX path to clipboard.
