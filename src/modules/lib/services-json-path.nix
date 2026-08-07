# Single store path for src/modules/services.json — used by watchdog daemons
# that cannot read repo-relative paths at runtime (launchd/systemd sandbox).
_:
builtins.path {
  path = ../services.json;
  name = "nucleus-services-json";
}
