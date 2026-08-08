# tests/integration/check-tests.nix — Structural assertions for modularized check scripts.

let
  inherit (import ../lib.nix) containsRegex;

  stepRunnerText = builtins.readFile ../../src/scripts/lib/step-runner.sh;
  stepRunnerPs1Text = builtins.readFile ../../src/scripts/lib/step-runner.ps1;
  checkShText = builtins.readFile ../../scripts/check.sh;
  checkPs1Text = builtins.readFile ../../scripts/check.ps1;
  checkStepsDir = ../../src/scripts/checks/check-steps;
  checkStepsFiles = builtins.attrNames (builtins.readDir checkStepsDir);
  hasSuffix = suffix: str: builtins.match ".*${suffix}" str != null;
  checkStepsSh = builtins.filter (f: hasSuffix ".sh" f) checkStepsFiles;
  checkStepsPs1 = builtins.filter (f: hasSuffix ".ps1" f) checkStepsFiles;

  libShText = builtins.readFile ../../src/scripts/lib/lib.sh;

  # Helper: read a step file and check it contains a pattern
  stepFileContains =
    stepName: pattern:
    let
      stepText = builtins.readFile (checkStepsDir + "/${stepName}");
    in
    builtins.match ".*${pattern}.*" stepText != null;
in

# ---- Framework library assertions ----

# register_step function present
assert containsRegex "register_step\\(\\)" stepRunnerText;
# _run_step wrapper present
assert containsRegex "_run_step\\(\\)" stepRunnerText;
# aggregate_results function present
assert containsRegex "aggregate_results\\(\\)" stepRunnerText;
# parse_args function present
assert containsRegex "parse_args\\(\\)" stepRunnerText;
# Wave parallelism infra
assert containsRegex "_wave_init" stepRunnerText;
assert containsRegex "_wave_cleanup" stepRunnerText;

# Step-runner.ps1: Register-Step, Invoke-Step, Invoke-StepPipeline, Format-StepSummary
assert containsRegex "Register-Step" stepRunnerPs1Text;
assert containsRegex "Invoke-Step" stepRunnerPs1Text;
assert containsRegex "Invoke-StepPipeline" stepRunnerPs1Text;
assert containsRegex "Format-StepSummary" stepRunnerPs1Text;

# ---- Thin orchestrator assertions (check.sh) ----
# Sources check-lib.sh and check-steps.sh
assert containsRegex "check-lib\\.sh" checkShText;
assert containsRegex "check-steps\\.sh" checkShText;
# Orchestration pipeline
assert containsRegex "parse_args" checkShText;
assert containsRegex "preflight_check" checkShText;
assert containsRegex "run_all_steps" checkShText;
assert containsRegex "aggregate_results" checkShText;

# ---- Thin orchestrator assertions (check.ps1) ----
assert containsRegex "check-lib\\.ps1" checkPs1Text;
assert containsRegex "check-steps\\.ps1" checkPs1Text;
assert containsRegex "Read-Argument" checkPs1Text;
assert containsRegex "Test-Prerequisite" checkPs1Text;
assert containsRegex "Invoke-StepPipeline" checkPs1Text;
assert containsRegex "Format-StepSummary" checkPs1Text;

# ---- Step file structure ----
# All 27 check step files exist for both platforms
assert builtins.length checkStepsSh == 27;
assert builtins.length checkStepsPs1 == 27;

# Each POSIX step file has a register_step call
assert builtins.all (f: stepFileContains f "register_step \"[^\"]*\" [0-9]+") checkStepsSh;

# Each Windows step file has a Register-Step call
assert builtins.all (
  f: stepFileContains f "Register-Step -Id \"[^\"]*\" -Number [0-9]+"
) checkStepsPs1;

# ---- ensure_tool function in lib.sh (unchanged) ----
assert containsRegex "ensure_tool" libShText;
assert containsRegex "run nucleus-apply" libShText;

{
  success = true;
  message = "Modularized check scripts structural assertions passed (framework functions, thin orchestrator, 27 step files per platform, register_step calls)";
}
