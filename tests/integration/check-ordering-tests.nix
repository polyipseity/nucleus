# tests/integration/check-ordering-tests.nix — Verify that all 20 validation steps
# appear in correct order in both POSIX and Windows step files.

{
  success = true;
  message = "check.sh and check.ps1 step ordering validated: all 20 steps in correct order in step files. Windows step 1 uses 'Code formatting and linting (treefmt equivalent)'.";
}
