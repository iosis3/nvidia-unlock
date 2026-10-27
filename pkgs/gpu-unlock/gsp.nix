# The GSP-RM image the unlock boots: gsp_ga10x.bin from NVIDIA's 610.43.03
# runfile, the release the unlock's Booter and V67 chain were made for.  The
# runfile is never executed.
{
  lib,
  stdenvNoCC,
  fetchurl,
  libarchive,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "gpu-unlock-gsp";
  version = "610.43.03";

  src = fetchurl {
    url = "https://download.nvidia.com/XFree86/Linux-x86_64/${finalAttrs.version}/NVIDIA-Linux-x86_64-${finalAttrs.version}.run";
    hash = "sha256-ReLUwTSiPDXlDyU6SqY+fl6NF+PRhdSgfIpY6WEu05I=";
  };

  dontUnpack = true;

  nativeBuildInputs = [ libarchive ];

  # hash of gpu-unlock/firmware/artifacts-610.43.03.json for the image inside
  # that runfile
  imageSha256 = "572373620a37418f24dc16b5031c39338778c3257e48e8408de9a57291b24f3a";

  # there is no reason to run NVIDIA's installer: ../unpack-runfile.sh
  installPhase = ''
    runHook preInstall
    source ${../unpack-runfile.sh}
    unpackRunfile "$src" unpack '*firmware/gsp_ga10x.bin'
    image=$(find unpack -type f -name gsp_ga10x.bin)
    [ -n "$image" ] || { echo "no firmware/gsp_ga10x.bin in the runfile" >&2; exit 1; }
    echo "$imageSha256  $image" | sha256sum -c -
    install -Dm644 "$image" "$out/gsp_ga10x.bin"
    runHook postInstall
  '';

  # a firmware blob: an ELF container that patchelf and strip must not touch
  dontFixup = true;

  meta = {
    description = "GSP-RM image from the NVIDIA ${finalAttrs.version} runfile, for gpu-unlock";
    license = lib.licenses.unfreeRedistributableFirmware;
    sourceProvenance = [ lib.sourceTypes.binaryFirmware ];
    platforms = [ "x86_64-linux" ];
  };
})
