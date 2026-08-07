# hosts/MacBook/filesystem-scope.nix — Documents host filesystem policy; no managed options.
#
# WHY: nix-darwin cannot repartition or reformat APFS volumes during
# nucleus-apply. APFS (and legacy HFS+ local folders) are the desired macOS
# defaults — see .agents/instructions/host-filesystem-scope.instructions.md.
#
# /nix is materialised via /etc/synthetic.conf during nucleus-bootstrap
# (ensure_macos_nix_mount in scripts/bootstrap.sh), not during apply.
#
# Removable NTFS read-write is managed via fuse-t, ntfs-3g, and Mounty
# (homebrew.nix, ntfs-3g.nix).
{ ... }: { }
