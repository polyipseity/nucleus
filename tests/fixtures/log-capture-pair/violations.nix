# Fixture: violations for the log capture pair policy.
{
  launchd.agents."fixture-discard" = {
    config = {
      StandardOutPath = "/dev/null";
      StandardErrorPath = "/dev/null";
    };
  };
}
