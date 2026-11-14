# Fixture: correct systemd service log capture, one file per stream.
{
  systemd.services."fixture-service" = {
    serviceConfig = {
      StandardOutput = "append:/logs/fixture-service/stdout.log";
      StandardError = "append:/logs/fixture-service/stderr.log";
    };
  };
}
