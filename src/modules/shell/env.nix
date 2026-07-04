# modules/shell/env.nix — Shared shell environment variables for all hosts.
#
# Keep keys strictly alphabetical so behavior remains predictable as the set
# grows and parity reviews can diff key order mechanically.
{
  # Prefer the LLVM toolchain everywhere so native-extension builds and C/C++
  # projects converge on clang/lld instead of host-specific defaults.
  # Sources:
  # https://clang.llvm.org/docs/CommandGuide/clang.html
  # https://lld.llvm.org/
  CC = "clang";
  CXX = "clang++";
  LD = "ld.lld";

  # Disable OpenCode auto-update checks globally across all platforms.
  # WHY: Managed environment controls OpenCode pinning; auto-updates can
  # introduce version skew across machines. Updates are intentional via
  # flake updates or package manager upgrades only.
  # Source: OpenCode CLI env var table (`OPENCODE_DISABLE_AUTOUPDATE`)
  # https://opencode.ai/docs/zh-tw/cli/#環境變數
  OPENCODE_DISABLE_AUTOUPDATE = "true";

  # Impose a 5-day minimum release age for uv package installations so newly
  # published (potentially compromised) packages must survive 5 days of public
  # scrutiny before they can be installed. This mirrors the industry-wide
  # supply-chain delay pattern adopted by npm, bun, pnpm, and Yarn.
  # Source: uv CLI env var table (`UV_EXCLUDE_NEWER`)
  # https://docs.astral.sh/uv/reference/settings/#exclude-newer
  UV_EXCLUDE_NEWER = "P5D";
}
