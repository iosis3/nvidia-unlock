# Zagitta/gpu-unlock's SEC2 kernel module, with the AD10x patch.  It runs the
# whole SEC2 transaction itself: it carries the Booter and the V67 signature
# chain (from gpu-unlock-firmware), boots a GSP-RM image with the chain in its
# signature section, and FLRs the card afterwards.  The NVIDIA driver is not
# involved -- it boots its own GSP-RM after that FLR.
#
# Lives in the kernel package set (`config.boot.kernelPackages.gpu-unlock`), so
# it is always built for the kernel the system boots.
{
  lib,
  stdenv,
  fetchFromGitHub,
  kernel,
  kernelModuleMakeFlags,
  binutils,
  xz,
  gpu-unlock-firmware,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "gpu-unlock";
  # no release tags upstream; 1.1.0 is the MODULE_VERSION ad10x-four-plm.patch sets
  version = "1.1.0-unstable-2026-10-24-${kernel.version}";

  src = fetchFromGitHub {
    owner = "Zagitta";
    repo = "gpu-unlock";
    rev = "af28cbbfd3d922a659227ecfb7369adfd924cf03";
    hash = "sha256-6FaDuPojB707ds7gkQY/g/+m4Tnz1xHZ95UjNfFxBJc=";
  };
  sourceRoot = "${finalAttrs.src.name}/kernel/gpu_unlock";

  patches = [
    ./ad10x-four-plm.patch
    ./fwsec-validate-before-start.patch
  ];

  nativeBuildInputs = kernel.moduleBuildDependencies;

  # out-of-tree modules are not shared objects; stdenv's -fPIC/-fformat
  # hardening breaks kbuild's module link
  hardeningDisable = [
    "format"
    "pic"
  ];

  # kbuild directly, not the repository's wrapper Makefile.  modules_install
  # strips, signs (the kernel's flags make cmd_sign kmodigest, which writes the
  # .ko.cer the NixOS module tree merges into modules.cer) and compresses.
  makeFlags = kernelModuleMakeFlags ++ [
    "-C"
    "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    "M=$(PWD)"
    "INSTALL_MOD_PATH=$(out)"
    "INSTALL_MOD_DIR=extra"
  ];
  buildFlags = [ "modules" ];
  installTargets = [ "modules_install" ];
  enableParallelBuilding = true;

  # The module asks request_firmware() for these exact names; if upstream ever
  # renames them, the firmware package and the module would disagree and the
  # unlock would fail at load time instead of at build time.  Read .modinfo with
  # readelf rather than `modinfo`, which prints nothing for a file argument.
  doInstallCheck = true;
  nativeInstallCheckInputs = [
    binutils
    xz
  ];
  installCheckPhase =
    let
      inherit (gpu-unlock-firmware) firmwareDir files;
    in
    ''
      runHook preInstallCheck
      ko=$out/lib/modules/${kernel.modDirVersion}/extra/gpu_unlock.ko
      [ -f "$ko.cer" ] || { echo "gpu-unlock: modules_install did not sign the module" >&2; exit 1; }
      if [ -f "$ko.xz" ]; then
        xz -dc "$ko.xz" > gpu_unlock.ko.uncompressed
        ko=gpu_unlock.ko.uncompressed
      fi
      readelf -p .modinfo "$ko" | sed -n 's/.*firmware=//p' | sort > requested
      printf '${firmwareDir}/%s\n' ${lib.escapeShellArgs files} | sort > installed
      diff -u installed requested
      runHook postInstallCheck
    '';

  # a .ko is ET_REL: patchelf and the RPATH audit cannot do anything with it,
  # and stdenv's strip would cut off the signature modules_install appended
  dontPatchELF = true;
  dontStrip = true;
  noAuditTmpdir = true;

  meta = {
    description = "Pre-driver SEC2 unlock of the GA10x/AD10x FP16/BF16 issue rate";
    homepage = "https://github.com/Zagitta/gpu-unlock";
    license = lib.licenses.gpl2Only;
    platforms = [ "x86_64-linux" ];
  };
})
