#!/usr/bin/env python
# /// script
# dependencies = []
# requires-python = ">=3.9.0"
# ///
"""Cross-platform Python wrapper for prek hooks.

Detects the OS and dispatches to the appropriate check/format commands.
On POSIX, uses nix run. On Windows, uses pwsh for PowerShell-based checks.
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path


def get_repo_root() -> Path:
    """Return the repository root directory.

    The script lives at <repo_root>/scripts/prek-hooks.py, so the repo root
    is two levels up from __file__.
    """
    return Path(__file__).resolve().parent.parent


def run_check(files: list[str], repo_root: Path) -> int:
    """Run the check hook."""
    if sys.platform != "win32":
        # POSIX: delegate entirely to nix
        env = os.environ.copy()
        env["NIX_CONFIG"] = "experimental-features = nix-command flakes"
        cmd = ["nix", "run", "./src#check"]
        if files:
            cmd.append("--")
            cmd.extend(files)
        result = subprocess.run(cmd, env=env, cwd=repo_root, shell=False)
        if result.returncode != 0:
            print(
                f"scripts/prek-hooks.py: error: check failed (exit {result.returncode})",
                file=sys.stderr,
            )
            return result.returncode
        return 0

    # Windows
    if not files:
        # No files specified: run all available checks, skip shellcheck
        for script in ("check-pwsh.ps1", "check-packer.ps1"):
            cmd = [
                "pwsh",
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-File",
                str(repo_root / "scripts" / script),
            ]
            result = subprocess.run(cmd, shell=False)
            if result.returncode != 0:
                print(
                    f"scripts/prek-hooks.py: error: check failed (exit {result.returncode})",
                    file=sys.stderr,
                )
                return result.returncode
        return 0

    # Group files by extension
    ps1_files = [f for f in files if f.endswith(".ps1")]
    pkr_files = [f for f in files if f.endswith(".pkr.hcl")]
    sh_files = [f for f in files if f.endswith(".sh")]

    for _ in sh_files:
        print("scripts/prek-hooks.py: shellcheck skipped (not available on Windows)")

    if not ps1_files and not pkr_files:
        return 0

    if ps1_files:
        cmd = [
            "pwsh",
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-File",
            str(repo_root / "scripts" / "check-pwsh.ps1"),
        ] + ps1_files
        result = subprocess.run(cmd, shell=False)
        if result.returncode != 0:
            print(
                f"scripts/prek-hooks.py: error: check failed (exit {result.returncode})",
                file=sys.stderr,
            )
            return result.returncode

    if pkr_files:
        cmd = [
            "pwsh",
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-File",
            str(repo_root / "scripts" / "check-packer.ps1"),
        ] + pkr_files
        result = subprocess.run(cmd, shell=False)
        if result.returncode != 0:
            print(
                f"scripts/prek-hooks.py: error: check failed (exit {result.returncode})",
                file=sys.stderr,
            )
            return result.returncode

    return 0


def run_format_nix(files: list[str], repo_root: Path) -> int:
    """Run the format-nix hook."""
    if sys.platform == "win32":
        print("scripts/prek-hooks.py: nixfmt skipped (not available on Windows)")
        return 0

    env = os.environ.copy()
    env["NIX_CONFIG"] = "experimental-features = nix-command flakes"
    cmd = ["nix", "run", "nixpkgs#nixfmt", "--", "-s", "--verify"]
    cmd.extend(files)
    result = subprocess.run(cmd, env=env, cwd=repo_root, shell=False)
    if result.returncode != 0:
        print(
            f"scripts/prek-hooks.py: error: format-nix failed (exit {result.returncode})",
            file=sys.stderr,
        )
        return result.returncode
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Cross-platform prek hook wrapper",
    )
    parser.add_argument(
        "hook",
        choices=["check", "format-nix"],
        help="Hook to run",
    )
    parser.add_argument(
        "files",
        nargs="*",
        help="Files to process",
    )
    args = parser.parse_args()

    repo_root = get_repo_root()

    if args.hook == "check":
        sys.exit(run_check(args.files, repo_root))
    elif args.hook == "format-nix":
        sys.exit(run_format_nix(args.files, repo_root))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(2)
