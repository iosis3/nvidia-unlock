# Applies this repository's patches to an NVIDIA driver (one of
# `nvidiaPackages.*`), each feature opt-in:
#
#   p2p              BAR1 P2P in the open kernel modules: the series
#                    ../nvidia-p2p lists for the driver's release
#   mixedGeneration  P2P between GPU generations: libcuda's peer-access
#                    policy, for a release whose series has the kernel side
#   nvenc            the NVENC concurrent session limit (libnvidia-encode)
#   nvfbc            the NvFBC capture check (libnvidia-fbc)
#
# The kernel patches extend the patch list of the driver's open kernel modules,
# where a branch in nixpkgs would list them as patchesOpen.  The userspace
# patches run in the driver's patch step against the libraries unpacked from
# the .run, before installPhase copies them; whether they fit a release is
# decided by the build: each signature has to match exactly once (userspace.sh).
{
  lib,
  nvidiaPackage,
  p2p ? false,
  mixedGeneration ? false,
  nvenc ? false,
  nvfbc ? false,
}:

let
  inherit (nvidiaPackage) version;

  p2pPatches = import ../nvidia-p2p;
  release =
    p2pPatches.${version}
      or (throw "nvidia-unlock: no P2P kernel patches for NVIDIA ${version}; patched releases: ${lib.concatStringsSep ", " (lib.attrNames p2pPatches)}");

  # userspace.sh's feature tags
  userspace = lib.attrNames (
    lib.filterAttrs (_: enabled: enabled) {
      mixed-generation = mixedGeneration;
      inherit nvenc nvfbc;
    }
  );
in
assert lib.assertMsg (p2p || userspace != [ ]) "nvidia-unlock: no patch feature enabled";
assert lib.assertMsg (mixedGeneration -> p2p) "nvidia-unlock: mixedGeneration needs p2p";
assert lib.assertMsg (
  mixedGeneration -> release.mixedGeneration
) "nvidia-unlock: the P2P kernel patches for NVIDIA ${version} do not do mixed-generation P2P";

nvidiaPackage.overrideAttrs (old: {
  # generic.nix passes postPatch = null through; toString null is ""
  postPatch =
    toString (old.postPatch or null)
    + lib.optionalString (userspace != [ ]) ''
      bash ${./userspace.sh} "$version" . ${lib.escapeShellArgs userspace}
    '';

  passthru =
    old.passthru
    // {
      nvidiaPatches = lib.optional p2p "p2p" ++ userspace;
    }
    // lib.optionalAttrs p2p {
      # what `hardware.nvidia.open = true` installs as boot.extraModulePackages
      open =
        if old.passthru.open or null == null then
          throw "nvidia-unlock: NVIDIA ${version} has no open kernel modules, which the P2P patches are for"
        else
          old.passthru.open.overrideAttrs (prev: {
            patches = prev.patches or [ ] ++ release.patches;
          });
    };
})
