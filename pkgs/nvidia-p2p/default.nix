# The open kernel module P2P patches per NVIDIA driver release, as nixpkgs'
# nvidia-x11/default.nix lists the patches of a branch, each re-created on its
# release (./refresh-patches.nix) from aikitoria/open-gpu-kernel-modules:
#
#   580.105.08-p2p, 590.48.01-p2p,  geohot's simplified mod, 5090 support (and
#   595.45.04-p2p                   the hugepage cudaHostRegister path on 595)
#   595.71.05-p2p (97fdda0, becbb56) the combined mod (geohot, 5090, NVLink) and
#                                   the hugepage path; for 595.104.02 its
#                                   combined mod, three-way ported, without
#                                   the hugepage commit, which conflicts there
#   615.71.09-p2p (e698b05, 43cb9fb) BAR1/NVLink P2P across GPU generations
#                                   with shared console mapping, hugepage path
#
# mixedGeneration: the series has the kernel side of P2P between GPU
# generations (e.g. RTX 3090 + 4090), which also needs the libcuda patch
# (patches.p2p.mixedGeneration).  Same-generation pairs need neither.
#
# keep: added by hand for a nixpkgs this flake does not follow (590.48.01 and
# 595.71.05 are nixos-26.05's new_feature and production); ./update.sh never
# drops such a release.  Remove the marker once that nixpkgs is gone.
#
# ./update.sh adds the releases the checked nixpkgs branches ship.
{
  "580.178.04" = {
    mixedGeneration = false;
    patches = [
      ./p2p-geohot-580.178.04.patch
      ./p2p-575-settings-580.178.04.patch
      ./p2p-5090-support-580.178.04.patch
    ];
  };
  "590.48.01" = {
    mixedGeneration = false;
    keep = true;
    patches = [
      ./p2p-geohot-590.48.01.patch
      ./p2p-575-settings-590.48.01.patch
      ./p2p-5090-support-590.48.01.patch
    ];
  };
  "595.45.04" = {
    mixedGeneration = false;
    patches = [
      ./p2p-geohot-595.45.04.patch
      ./p2p-575-settings-595.45.04.patch
      ./p2p-5090-support-595.45.04.patch
      ./p2p-hugepage-host-register-595.45.04.patch
    ];
  };
  "595.71.05" = {
    mixedGeneration = false;
    keep = true;
    patches = [
      ./p2p-combined-595.71.05.patch
      ./p2p-hugepage-host-register-595.71.05.patch
    ];
  };
  "595.104.02" = {
    mixedGeneration = false;
    patches = [
      ./p2p-combined-595.104.02.patch
    ];
  };
  "615.78.08" = {
    mixedGeneration = true;
    patches = [
      ./p2p-bar1-nvlink-shared-console-615.78.08.patch
      ./p2p-hugepage-host-register-615.78.08.patch
    ];
  };
}
