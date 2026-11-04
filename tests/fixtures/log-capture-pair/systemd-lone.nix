# Fixture: a systemd service that captures only its stdout stream.
{
  systemd.services."fixture-lone-service" = {
    serviceConfig = {
      StandardOutput = "append:/logs/fixture-lone-service/stdout.log";
    };
  };
}
