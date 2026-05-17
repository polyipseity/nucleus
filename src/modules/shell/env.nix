# modules/shell/env.nix — Shared shell environment variables for all hosts.
#
# Keep keys strictly alphabetical so behavior remains predictable as the set
# grows and parity reviews can diff key order mechanically.
{
  # Prefer the LLVM toolchain everywhere so native-extension builds and C/C++
  # projects converge on clang/lld instead of host-specific defaults.
  CC = "clang";
  CXX = "clang++";
  LD = "ld.lld";

  # Disable OpenCode auto-update globally across all platforms.
  # WHY: Managed environment controls OpenCode pinning; auto-updates can
  # introduce version skew across machines. Updates are intentional via
  # flake updates or package manager upgrades only.
  OPENCODE_NO_UPDATE_CHECK = "1";
}
