# Safe-delete provisioning tests.
let
  inherit (import ../lib.nix) assert';
  coreText = builtins.readFile ../../src/modules/core.nix;
  desired = builtins.fromJSON (builtins.readFile ../../src/modules/packages/desired.json);
  hasRip2 = builtins.match ".*rip2 = \\{.*" coreText != null;
  hasSafeRm = builtins.any (e: e.name == "safe-rm") (desired.bun.MacBook or [ ]);
in
builtins.seq (builtins.deepSeq { inherit hasRip2 hasSafeRm; } null) {
  "rip2 in managedPackages" = assert' hasRip2 "rip2";
  "safe-rm in bun desired" = assert' hasSafeRm "safe-rm";
}
