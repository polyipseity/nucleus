# Fixture: correct service log capture — the stdout.log/stderr.log pair.
{
  launchd.agents."fixture-agent" = {
    config = {
      StandardOutPath = "/logs/fixture-agent/stdout.log";
      StandardErrorPath = "/logs/fixture-agent/stderr.log";
    };
  };
}
