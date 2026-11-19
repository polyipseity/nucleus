# WHY: macOS nix-darwin activation runs under /bin/bash 3.2.57, so any guarded
# bundle script that requires bash 5.1 breaks when its shebang resolves via
# /usr/bin/env bash on PATH. The Nix store bundles are the only place we can
# supply the interpreter, so rewrite the repo's #!/usr/bin/env bash first line
# to the pinned store bash at build time.
{ pkgs }:
{
  rewriteBashShebang = dir: ''
    find "${dir}" -type f -name '*.sh' -exec ${pkgs.gnused}/bin/sed -i '1s|^#!/usr/bin/env bash$|#!${pkgs.bash}/bin/bash|' {} +
  '';
}
