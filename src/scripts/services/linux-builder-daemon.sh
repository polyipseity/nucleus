# Linux builder VM daemon — keeps the NixOS builder running via
# Apple Virtualization.framework.
# Tokens substituted at build time by Nix:
#   __WORK_DIR__, __CREATE_BUILDER_BIN__
export TMPDIR=/run/org.nixos.linux-builder USE_TMPDIR=1
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"
mkdir -p "__WORK_DIR__"
trap "rm -rf $TMPDIR" EXIT
exec __CREATE_BUILDER_BIN__
