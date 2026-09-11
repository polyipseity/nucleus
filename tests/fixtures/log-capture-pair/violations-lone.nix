# Fixture: a lone capture stream — its sibling is neither captured nor discarded.
{
  launchd.agents."fixture-lone" = {
    config = {
      StandardOutPath = "/logs/fixture-lone/stdout.log";
    };
  };
}
