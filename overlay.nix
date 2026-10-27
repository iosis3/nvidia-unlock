# The packages, for use outside the NixOS module (which does not need this):
#
#   gpu-unlock            in every kernel package set, so it follows
#                         boot.kernelPackages
#   gpu-unlock-firmware   kernel independent
#   gpu-unlock-gsp        the GSP-RM image the firmware includes
#
# The driver patches are not a package: they apply to a driver, see
# lib.patchNvidiaDriver in flake.nix.
final: prev: {
  kernelPackagesExtensions = prev.kernelPackagesExtensions ++ [
    (kfinal: _kprev: {
      gpu-unlock = kfinal.callPackage ./pkgs/gpu-unlock/module.nix { };
    })
  ];

  gpu-unlock-firmware = final.callPackage ./pkgs/gpu-unlock/firmware.nix { };
  gpu-unlock-gsp = final.callPackage ./pkgs/gpu-unlock/gsp.nix { };
}
