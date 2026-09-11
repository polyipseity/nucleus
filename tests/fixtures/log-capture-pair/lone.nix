# Test fixture: a capture directive that captures only one of the two streams.
# Deliberately violates the stdout.log/stderr.log pair policy so the guard's
# lone-stream rule has something to detect.
{
  launchd.agents.example = {
    config = {
      StandardErrorPath = "/logs/example/stderr.log";
    };
  };
}
