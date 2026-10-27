# Runs the userspace signatures of `features` against one nixpkgs driver's .run,
# without building the driver: a cheap check that a nixpkgs bump did not move a
# release out from under a signature.
{
  lib,
  runCommand,
  libarchive,
  nvidiaPackage,
  features,
}:

runCommand "nvidia-unlock-userspace-${nvidiaPackage.version}"
  {
    inherit (nvidiaPackage) src version;
    nativeBuildInputs = [ libarchive ];
  }
  ''
    source ${../unpack-runfile.sh}
    unpackRunfile "$src" run \
      "*libcuda.so.$version" "*libnvidia-encode.so.$version" "*libnvidia-fbc.so.$version"
    libdir=$(find run -name "libcuda.so.$version" -not -path '*/32/*' -printf '%h\n' | head -n1)
    bash ${./userspace.sh} "$version" "$libdir" ${lib.escapeShellArgs features} | tee $out
  ''
