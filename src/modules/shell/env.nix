# modules/shell/env.nix — Shared shell environment variables for all hosts.
#
# Keep keys strictly alphabetical so behavior remains predictable as the set
# grows and parity reviews can diff key order mechanically.
{ pkgs }: {
  # Prefer the LLVM toolchain everywhere so native-extension builds and C/C++
  # projects converge on clang/lld instead of host-specific defaults.
  # Sources:
  # https://clang.llvm.org/docs/CommandGuide/clang.html
  # https://lld.llvm.org/
  #
  # WHY absolute store paths (not bare "clang"): bare names resolve to
  # /usr/bin/clang outside Nix build environments, which calls xcrun and
  # triggers the Xcode CLT installation dialog on macOS. Absolute store
  # paths bypass PATH resolution entirely, so CC/CXX work in sudo, launchd
  # services, VS Code tasks, and rustup cargo builds without xcrun.
  #
  # Scope: shell-only on macOS (WHY Nix LLVM paths in GUI process env
  # interfere with Xcode toolchain discovery). All-process on NixOS/Windows.
  CC = "${pkgs.llvmPackages.clang}/bin/clang";
  CXX = "${pkgs.llvmPackages.clang}/bin/clang++";
  LD = "${pkgs.llvmPackages.lld}/bin/ld.lld";

  # Disable OpenCode auto-update checks globally across all platforms.
  # WHY: Managed environment controls OpenCode pinning; auto-updates can
  # introduce version skew across machines. Updates are intentional via
  # flake updates or package manager upgrades only.
  # Source: OpenCode CLI env var table (`OPENCODE_DISABLE_AUTOUPDATE`)
  # https://opencode.ai/docs/zh-tw/cli/#環境變數
  # Scope: all-process — also set in gui-env LaunchAgent on macOS.
  OPENCODE_DISABLE_AUTOUPDATE = "true";

}
