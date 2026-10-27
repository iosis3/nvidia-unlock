# unpackRunfile RUNFILE DIR PATTERN...
#
# Extracts the members of an NVIDIA .run matching the bsdtar PATTERNs into DIR,
# without running it: its own extractor unpacks a dynamically linked zstd that
# cannot run in the sandbox.  A makeself archive carries the line its
# compressed tar starts at as `skip=N`; the first such line is the header's,
# the rest of the file is binary.  bsdtar detects zstd/xz/gzip itself, the
# fallback nixpkgs' nvidia-x11 builder.sh uses too.  Needs libarchive.
unpackRunfile() {
  local run=$1 dir=$2 skip pattern
  local -a include=()
  shift 2
  skip=$(sed -n '/^skip=/{s///p;q}' "$run")
  [[ -n $skip ]] || { echo "$run: no makeself skip= line" >&2; return 1; }
  for pattern; do include+=(--include "$pattern"); done
  mkdir -p "$dir"
  tail -n +"$skip" "$run" | bsdtar -xf - -C "$dir" "${include[@]}"
}
