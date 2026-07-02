#!/usr/bin/env python
# /// script
# dependencies = []
# requires-python = ">=3.9.0"
# ///
"""Cross-platform Python wrapper for prek hooks.

On POSIX, runs ``scripts/check.sh`` directly. On Windows, uses pwsh for
PowerShell-based checks.
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path


def get_repo_root() -> Path:
    """Return the repository root directory.

    The script lives at ``<repo_root>/scripts/prek-hooks.py``, so the repo
    root is two levels up from the script file.

    Returns:
        Absolute path to the repository root directory.
    """
    return Path(__file__).resolve().parent.parent


def run_check(files: list[str], repo_root: Path, format_enabled: bool = False) -> int:
    """Run the check hook.

    On POSIX, delegates to ``scripts/check.sh`` directly (tools are available
    via the user profile or direnv dev shell).  On Windows, dispatches to
    ``check-pwsh.ps1`` and/or ``check-packer.ps1`` depending on which file
    extensions are present, or runs all available checks when no files are
    given.

    Args:
        files: List of file paths (relative or absolute) to check.  May be
            empty, in which case all available checks are run.
        repo_root: Absolute path to the repository root, used to locate
            the check scripts.
        format_enabled: If True, pass ``--format`` to format Nix files
            in-place instead of just validating.

    Returns:
        Exit code from the underlying check process(es).  0 on success,
        non-zero on failure.
    """
    if sys.platform != "win32":
        # Direct call is safe because the required tools (nixfmt, pwsh, packer)
        # are available in the default devShell (loaded by .envrc use flake).
        cmd = [str(repo_root / "scripts" / "check.sh")]
        if format_enabled:
            cmd.append("--format")
        if files:
            cmd.extend(files)
        result = subprocess.run(cmd, cwd=repo_root, shell=False)
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


def run_test(files: list[str], repo_root: Path) -> int:
    """Run the test suite.

    On POSIX, delegates to ``nix run ./src#test``.  On Windows, runs
    ``scripts/test.ps1`` as a placeholder (future Windows test support).

    Args:
        files: List of file paths (ignored — tests always run full suite).
        repo_root: Absolute path to the repository root.

    Returns:
        Exit code from the underlying test process.  0 on success, non-zero
        on failure.
    """
    if sys.platform != "win32":
        env = os.environ.copy()
        env["NIX_CONFIG"] = "experimental-features = nix-command flakes"
        cmd = ["nix", "run", "./src#test"]
        result = subprocess.run(cmd, env=env, cwd=repo_root, shell=False)
        if result.returncode != 0:
            print(
                f"scripts/prek-hooks.py: error: test failed (exit {result.returncode})",
                file=sys.stderr,
            )
            return result.returncode
        return 0

    # Windows: placeholder
    cmd = [
        "pwsh",
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-File",
        str(repo_root / "scripts" / "test.ps1"),
    ]
    result = subprocess.run(cmd, shell=False)
    if result.returncode != 0:
        print(
            f"scripts/prek-hooks.py: error: test failed (exit {result.returncode})",
            file=sys.stderr,
        )
        return result.returncode
    return 0


def main() -> int:
    """Entry point for the prek hook wrapper.

    Parses command-line arguments, resolves the repository root, and
    dispatches to the appropriate hook implementation (``check`` or
    ``test``).

    Returns:
        Exit code from the dispatched hook.  0 on success, non-zero on
        failure.  Returns 1 for an unrecognized hook name.
    """
    parser = argparse.ArgumentParser(
        description="Cross-platform prek hook wrapper",
    )
    parser.add_argument(
        "--format",
        action="store_true",
        help="Format Nix files in-place (instead of just validating)",
    )
    parser.add_argument(
        "hook",
        choices=["check", "test"],
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
        return run_check(args.files, repo_root, format_enabled=args.format)
    elif args.hook == "test":
        return run_test(args.files, repo_root)
    else:
        print(
            f"scripts/prek-hooks.py: error: unknown hook '{args.hook}'", file=sys.stderr
        )
        return 1


def __main__() -> None:
    """Run the main entry point and translate the return code to an exit.

    Wraps ``main()`` so that its integer return value becomes the process
    exit code.  Catches ``KeyboardInterrupt`` and exits with code 2.
    """
    try:
        exit(main())
    except KeyboardInterrupt:
        exit(2)


if __name__ == "__main__":
    __main__()
