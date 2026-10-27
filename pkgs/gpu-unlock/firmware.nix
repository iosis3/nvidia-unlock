# The firmware gpu-unlock's module requests: the SEC2 Booter, GSP boot image
# and descriptor per architecture, the V67 signature chains and the GSP-RM
# image.  Independent of the kernel and of the NVIDIA driver the system runs.
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  python3,
  gpu-unlock-gsp,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "gpu-unlock-firmware";
  # the release the module's request_firmware() names; its Booter is the one
  # the V67 chain is mined against
  version = "610.43.03";

  # The 610.43.03 Booter (and the GSP boot image/descriptor) are byte-identical
  # in 615.71.09, which is why that tag is the source: nixpkgs pins the same
  # tarball hash.  boot-assets.py refuses anything else.
  src = fetchFromGitHub {
    owner = "NVIDIA";
    repo = "open-gpu-kernel-modules";
    tag = "615.71.09";
    hash = "sha256-3gByMYIwFzRaLdDG+roCEOuKRRJDrljG9AlLnRZTirM=";
  };

  nativeBuildInputs = [ python3 ];

  buildPhase = ''
    runHook preBuild
    python3 ${./boot-assets.py} . assets
    python3 ${./v67-payload.py} assets
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm644 -t "$out/lib/firmware/${finalAttrs.passthru.firmwareDir}" \
      assets/* ${gpu-unlock-gsp}/gsp_ga10x.bin
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    ls "$out/lib/firmware/${finalAttrs.passthru.firmwareDir}" | sort > installed
    printf '%s\n' ${lib.escapeShellArgs finalAttrs.passthru.files} | sort > expected
    diff -u expected installed
    runHook postInstallCheck
  '';

  # firmware blobs, fed to the SEC2/GSP boot byte for byte: nothing to patch or
  # strip, and patchelf only trips over the GSP-RM image ("wrong ELF type")
  dontFixup = true;

  passthru = {
    # where the module looks, and what it looks for (its build checks both)
    firmwareDir = "gpu-unlock/${finalAttrs.version}";
    files = [
      # GA10x (RTX 30xx) + AD10x (RTX 40xx) share the GSP-RM image but not the
      # Booter, GSP boot image or signature chain
      "booter_load_ga102.bin"
      "v67-ga102-${finalAttrs.version}.bin"
      "gsp_ga10x.bin"
      "gsp_boot_ga102.bin"
      "gsp_boot_desc_ga102.bin"
      "booter_load_ad102.bin"
      "v67-ad102-${finalAttrs.version}-four-plm.bin"
      "gsp_boot_ad102.bin"
      "gsp_boot_desc_ad102.bin"
    ];
  };

  meta = {
    description = "SEC2 Booter, GSP boot image, GSP-RM and V67 signatures for gpu-unlock";
    license = lib.licenses.unfreeRedistributableFirmware; # the GSP-RM image
    sourceProvenance = [ lib.sourceTypes.binaryFirmware ];
    platforms = [ "x86_64-linux" ];
  };
})
