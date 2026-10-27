# P2P kernel patches re-created on a driver's own open-gpu-kernel-modules
# source: `git am` of each patch (no fuzz, unlike the patch phase), then
# `git format-patch`.  $out holds them under their names with the release
# suffix replaced by the driver's version: for a release in ./default.nix the
# committed patches re-created (nothing compares them; a port diffs by hand);
# for a new release (./update.sh) the patches ported to it, or the build fails
# because a hunk does not apply.
{
  lib,
  runCommand,
  git,
  driver,
  patches,
}:

let
  # p2p-bar1-nvlink-shared-console-615.78.08.patch -> p2p-bar1-nvlink-shared-console
  purpose =
    patch:
    let
      m = builtins.match "(.*)-[0-9][0-9.]*\\.patch" (baseNameOf patch);
    in
    if m == null then throw "nvidia-unlock: ${baseNameOf patch} has no release suffix" else lib.head m;
in
runCommand "nvidia-p2p-patches-${driver.version}"
  {
    inherit (driver.open) src;
    nativeBuildInputs = [ git ];
  }
  ''
    cp -r --no-preserve=mode "$src" source
    cd source
    export GIT_AUTHOR_NAME=nvidia-unlock GIT_AUTHOR_EMAIL=nvidia-unlock@localhost
    export GIT_COMMITTER_NAME=nvidia-unlock GIT_COMMITTER_EMAIL=nvidia-unlock@localhost
    git init -q
    git add -A
    git commit -q -m ${driver.version}
    # ./update.sh tells "does not apply" from any other failure by this line
    ${lib.concatMapStrings (patch: ''
      git am -q --whitespace=nowarn ${patch} ||
        { echo "nvidia-unlock: ${baseNameOf patch} does not apply to ${driver.version}" >&2; exit 1; }
    '') patches}
    git format-patch -q --zero-commit --no-signature --no-numbered -o ../series HEAD~${toString (lib.length patches)}
    mkdir $out
    set -- ../series/*.patch
    ${lib.concatMapStrings (patch: ''
      cp "$1" $out/${purpose patch}-${driver.version}.patch
      shift
    '') patches}
  ''
