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
}
