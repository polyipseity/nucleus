# modules/lib/camilladsp-python.nix - one Python environment for the CamillaDSP
# heartbeat on every POSIX host.
#
# WHY: declared once instead of per host. The daemon imports PyYAML and a
# websockets client, and a host that forgot one would fail only at runtime,
# inside a launchd or systemd unit where nobody reads the traceback.
{ pkgs }:
pkgs.python3.withPackages (p: [
  p.pyyaml
  p.websockets
])
