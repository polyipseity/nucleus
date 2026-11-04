# Fixture: a merged redirection above a /dev/null discard, so the two rules run
# out of line order and a pass has to keep the report order the grep version had.
{
  launchd.agents."fixture-order" = {
    config = {
      ProgramArguments = [
        "/bin/sh"
        "-c"
        "exec fixture-bin *>> /logs/fixture/all.log"
      ];
      StandardOutPath = "/dev/null";
      StandardErrorPath = "/logs/fixture/stderr.log";
    };
  };
}
