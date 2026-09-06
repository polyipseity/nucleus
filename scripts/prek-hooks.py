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


def run_check(files: list[str], repo_root: Path, scoped: bool = False) -> int:
    """Run the check hook.

    On POSIX, delegates to ``scripts/check.sh`` directly (tools are available
    via the user profile or direnv dev shell).  On Windows, delegates to
    ``scripts/check.ps1`` (which internally handles extension routing to
    ``check-pwsh.ps1`` and ``check-packer.ps1``).

    Args:
        files: List of file paths (relative or absolute) to check.  May be
            empty, in which case all available checks are run.
        repo_root: Absolute path to the repository root, used to locate
            the check scripts.
        scoped: If True, pass ``--scoped`` to run in scoped mode
            (skip whole-repo checks).

    Returns:
        Exit code from the underlying check process(es).  0 on success,
        non-zero on failure.
    """
    if sys.platform != "win32":
        # Direct call is safe because required tools (treefmt, pwsh, packer)
        # are provisioned on PATH via bootstrap-deps and core.nix sharedPackages
        # (flake mkTreefmtWrapper), not only the Nix dev shell.
        # Intentionally NOT passing --no-fail-fast: check accumulates by default
        # (no-fail-fast). Runs on every commit — should report all issues.
        cmd = [str(repo_root / "scripts" / "check.sh")]
        if scoped:
            cmd.append("--scoped")
        if files:
            cmd.extend(files)
        result = subprocess.run(cmd, cwd=repo_root, shell=False, check=False)
        if result.returncode != 0:
            print(
                f"scripts/prek-hooks.py: error: check failed (exit {result.returncode})",
                file=sys.stderr,
            )
            return result.returncode
        return 0

    # Windows — check.ps1 handles extension routing internally (same as check.sh)
    cmd = [
        "pwsh",
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-File",
        str(repo_root / "scripts" / "check.ps1"),
    ]
    if scoped:
        cmd.append("--scoped")
    if files:
        cmd.extend(files)
    result = subprocess.run(cmd, shell=False, check=False)
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

    The test suite runs the full suite and does not accept file arguments —
    the ``files`` parameter is accepted for API consistency but ignored.

    Args:
        files: Ignored (test suite does not scope by file).
        repo_root: Absolute path to the repository root.

    Returns:
        Exit code from the underlying test process.  0 on success, non-zero
        on failure.
    """
    if sys.platform != "win32":
        env = os.environ.copy()
        env["NIX_CONFIG"] = "experimental-features = nix-command flakes"
        # Intentionally NOT passing --no-fail-fast: test defaults to fail-fast.
        # CI explicitly passes --no-fail-fast to accumulate all failures.
        cmd = ["nix", "run", "./src#test"]
        result = subprocess.run(cmd, env=env, cwd=repo_root, shell=False, check=False)
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
    result = subprocess.run(cmd, shell=False, check=False)
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
        "--scoped",
        action="store_true",
        help="Run in scoped mode (skip whole-repo checks)",
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
        return run_check(args.files, repo_root, scoped=args.scoped)
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
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(2)


if __name__ == "__main__":
    __main__()
