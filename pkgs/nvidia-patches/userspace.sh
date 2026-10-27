# Apply the userspace patches to NVIDIA's proprietary shared libraries.
#
#   bash userspace.sh VERSION LIBDIR FEATURE...
#
# LIBDIR is an unpacked driver, so this runs in the patch step.  FEATURE is any
# of mixed-generation (libcuda), nvenc and nvfbc; only the patches tagged with
# one of them are applied.
#
# Each patch is a byte signature plus the bytes to write -- the way these patches
# have always been described for NVENC and for mixed-generation P2P.  `??` stands
# for any byte and is used for call and branch displacements, so a signature
# survives code that moves or grows; everything else is literal, which is what
# makes it specific (`85 c0 0f 85` alone matches 293 times in libnvidia-fbc.so).
#
# Every signature has to match exactly once: no match means the code changed in
# this release, more than one means the signature is ambiguous (an inlined
# copy).  Either is a build failure -- shipping an unpatched library silently is
# the failure mode this replaces.  That check is also what decides whether a
# release is supported: nothing here is tied to one driver version, a signature
# applies to every release it matches.
#
# RELEASES is a bash pattern over the driver version (`*`, `595.*`, ...).  When a
# release needs a different signature for the same change, add the variant with
# a pattern for that release and narrow the existing entry so that exactly one
# of them is tried.  checks.userspace-<release> run them against a driver.
#
# The comments are radare2 disassembly of the 615.78.08 libraries, showing where
# the match lands in that build; the signatures were verified on the releases
# listed with each entry.
set -euo pipefail

# feature | releases | lib | what | signature (?? = any byte) | offset in the match | new bytes
readonly -a PATCHES=(
  # libnvidia-encode.so: the concurrent NVENC session limit.
  #
  #   0x00024d83      mov rdi, r15
  #   0x00024d86      mov edx, dword [rsp + 0xc]
  #   0x00024d8a      call 0x6ad0
  #   0x00024d8f      mov r14d, eax
  #   0x00024d92      test eax, eax
  #   0x00024d94      jne 0x24e40
  #
  # `mov r14d,eax; test eax,eax` becomes `sub eax,eax; mov r14d,eax`: eax is
  # zeroed and ZF is set, so the branch to the refusal path is never taken, and
  # the instruction length is unchanged so the following code stays aligned.
  # verified: 580.178.04 590.48.01 595.45.04 595.71.05 595.104.02 615.78.08
  'nvenc|*|libnvidia-encode|NVENC session limit|4c 89 ff 8b 54 24 0c e8 ?? ?? ?? ?? 41 89 c6 85 c0 0f 85 ?? ?? ?? ??|12|29 c0 41 89 c6'

  # libnvidia-fbc.so: the NvFBC capture check.
  #
  #   0x00008fb3      mov rdi, qword [rbp + 0x28]
  #   0x00008fb7      call 0x20b70
  #   0x00008fbc      test eax, eax
  #   0x00008fbe      jne 0x90e0
  #   0x00008fc4      lea rdi, [rbp + 0x30]
  #
  # The conditional branch (6 bytes) becomes six nops, so execution always falls
  # through to the setup path that follows.
  # verified: 580.178.04 590.48.01 595.45.04 595.71.05 595.104.02 615.78.08
  'nvfbc|*|libnvidia-fbc|NvFBC capture check|48 8b 7d 28 e8 ?? ?? ?? ?? 85 c0 0f 85 ?? ?? ?? ?? 48 8d 7d 30|11|90 90 90 90 90 90'

  # libcuda.so: peer-access policy for mixed-generation P2P (aikitoria's
  # patch-libcuda-p2p.py for 615.71.09).  Verified: 615.78.08.  The first two
  # also match 595.x, the others do not; none matches 580.  Each predicate
  # compares the GPU family of both devices, read from [device+0xc50], and only
  # lets equal or specially listed families through; turning the first `je` into
  # an unconditional `jmp` skips the policy entirely.
  #
  #   0x0031ee44      mov rax, qword [rbx + 0xc50]
  #   0x0031ee4b      mov rdx, qword [r12 + 0xc50]
  #   0x0031ee53      cmp rax, rdx
  #   0x0031ee56      je 0x31ee9c
  #   0x0031ee58      cmp rax, 0xc0
  #   0x0031ee5e      jne 0x31ee69
  #   0x0031ee60      cmp rdx, 0xc8
  #   0x0031ee67      je 0x31ee9c
  #   0x0031ee69      cmp rax, 0xc8
  #   0x0031ee6f      jne 0x31ee7a
  #   0x0031ee71      cmp rdx, 0xc0
  #   0x0031ee78      je 0x31ee9c
  #   0x0031ee7a      and eax, 0xfffffff0
  #   0x0031ee7d      cmp rax, 0xf0
  #   0x0031ee83      je 0x31ee90
  #   0x0031ee85      xor eax, eax
  'mixed-generation|*|libcuda|P2P: can-access predicate|48 8b 83 50 0c 00 00 49 8b 94 24 50 0c 00 00 48 39 d0 74 ?? 48 3d c0 00 00 00 75 ?? 48 81 fa c8 00 00 00 74 ?? 48 3d c8 00 00 00 75 ?? 48 81 fa c0 00 00 00 74 ?? 83 e0 f0 48 3d f0 00 00 00 74 ?? 31 c0|18|eb'

  #   0x0031f050      mov rax, qword [rdi + 0xc50]
  #   0x0031f057      mov rdx, qword [rbx + 0xc50]
  #   0x0031f05e      cmp rax, rdx
  #   0x0031f061      je 0x31f0a8
  #   0x0031f063      cmp rax, 0xc0
  #   0x0031f069      jne 0x31f074
  #   0x0031f06b      cmp rdx, 0xc8
  #   0x0031f072      je 0x31f0a8
  #   0x0031f074      cmp rax, 0xc8
  #   0x0031f07a      jne 0x31f085
  #   0x0031f07c      cmp rdx, 0xc0
  #   0x0031f083      je 0x31f0a8
  #   0x0031f085      and eax, 0xfffffff0
  #   0x0031f088      cmp rax, 0xf0
  #   0x0031f08e      jne 0x31f09c
  #   0x0031f090      and edx, 0xfffffff0
  #   0x0031f093      cmp rdx, 0xf0
  #   0x0031f09a      je 0x31f0a8
  'mixed-generation|*|libcuda|P2P: compatibility predicate|48 8b 87 50 0c 00 00 48 8b 93 50 0c 00 00 48 39 d0 74 ?? 48 3d c0 00 00 00 75 ?? 48 81 fa c8 00 00 00 74 ?? 48 3d c8 00 00 00 75 ?? 48 81 fa c0 00 00 00 74 ?? 83 e0 f0 48 3d f0 00 00 00 75 ?? 83 e2 f0|17|eb'

  #   0x004ba723      mov rax, qword [r15 + 0xc50]
  #   0x004ba72a      mov rdx, qword [r14 + 0xc50]
  #   0x004ba731      cmp rax, rdx
  #   0x004ba734      je 0x4ba7b0
  #   0x004ba736      cmp rdx, 0xc8
  #   0x004ba73d      jne 0x4ba747
  'mixed-generation|*|libcuda|P2P: peer-device selection|49 8b 87 50 0c 00 00 49 8b 96 50 0c 00 00 48 39 d0 74 ?? 48 81 fa c8 00 00 00 75 ?? 48 3d c0 00 00 00 74 ?? 48 81 fa c0 00 00 00 75 ?? 48 3d c8 00 00 00 74 ?? 83 e0 f0 48 3d f0 00 00 00 75 ?? 83 e2 f0 48 81 fa f0 00 00 00 74 ??|17|eb'

  #   0x0031ef49      mov rax, qword [rbx + 0xc50]
  #   0x0031ef50      mov rdx, qword [r12 + 0xc50]
  #   0x0031ef58      cmp rax, rdx
  #   0x0031ef5b      je 0x31efb0
  #   0x0031ef5d      cmp rax, 0xc0
  #   0x0031ef63      jne 0x31ef6e
  'mixed-generation|*|libcuda|P2P: peer setup|48 8b 83 50 0c 00 00 49 8b 94 24 50 0c 00 00 48 39 d0 74 ?? 48 3d c0 00 00 00 75 ?? 48 81 fa c8 00 00 00 74 ?? 48 3d c8 00 00 00 75 ?? 48 81 fa c0 00 00 00 74 ?? 83 e0 f0 48 3d f0 00 00 00 75 ?? 83 e2 f0 48 81 fa f0 00 00 00 74 ??|18|eb'
)

die() { printf 'nvidia-unlock: %s\n' "$*" >&2; exit 1; }

tmpdir=
libdir=.
version=
declare -A hexdump_of=() mode_of=()

cleanup() {
  local lib
  for lib in "${!mode_of[@]}"; do
    chmod "${mode_of[$lib]}" "$libdir/$lib.so.$version" 2>/dev/null || true
  done
  [[ -n $tmpdir ]] && rm -rf "$tmpdir"
}

# hexdump the library once; the signature match runs on that text so that
# patterns containing NUL or newline bytes need no special handling.  Every
# byte is ` xx`, three characters with a leading space, so a match can only
# start on a byte boundary, never halfway into one
hexdump_of() {
  local lib=$1 file=$libdir/$1.so.$version hex
  if [[ -z ${hexdump_of[$lib]-} ]]; then
    [[ -f $file ]] || die "$file: no such library"
    hex=$tmpdir/$lib.hex
    od -An -v -tx1 "$file" | tr -d '\n' >"$hex"
    hexdump_of[$lib]=$hex
    mode_of[$lib]=$(stat -c %a "$file")
    chmod u+w "$file"
  fi
}

apply_patch() {
  local lib=$1 what=$2 sig=$3 off=$4 new=$5
  local file=$libdir/$lib.so.$version hex hits=() pat='' where='' bytes='' tok i siglen=0 start
  local -a tokens

  hexdump_of "$lib"
  hex=${hexdump_of[$lib]}

  # read into an array: iterating the unquoted string would glob `??` against
  # whatever two-character files the working directory happens to contain
  read -r -a tokens <<<"$sig"
  for tok in "${tokens[@]}"; do
    if [[ $tok == '??' ]]; then pat+=' ..'; else pat+=" $tok"; fi
    siglen=$((siglen + 1))
  done

  mapfile -t hits < <(LC_ALL=C grep -aboE -e "$pat" "$hex" | cut -d: -f1)

  if [[ ${#hits[@]} -ne 1 ]]; then
    if [[ ${#hits[@]} -eq 0 ]]; then
      where=nowhere
    else
      for i in "${hits[@]}"; do where+="0x$((i / 3)), "; done
      where=${where%, }
    fi
    die "$lib: $what: signature matched ${#hits[@]} times ($where), expected exactly one (already patched?)"
  fi
  start=$((hits[0] / 3))

  new=${new// /}
  ((off + ${#new} / 2 <= siglen)) ||
    die "$lib: $what: replacement at +$off (${#new} / 2 bytes) is outside the $siglen-byte signature"

  for ((i = 0; i < ${#new}; i += 2)); do
    bytes+="\\x${new:i:2}"
  done
  printf '%b' "$bytes" | dd of="$file" bs=1 seek=$((start + off)) conv=notrunc status=none
  printf 'nvidia-unlock: %s: %s at 0x%x\n' "$lib.so.$version" "$what" $((start + off))
}

main() {
  local entry feature releases lib what sig off new
  local -A wanted=() applied=()
  (( $# >= 3 )) || die "usage: ${0##*/} VERSION LIBDIR FEATURE..."
  version=$1
  libdir=$2
  shift 2
  for feature; do wanted[$feature]=1; done

  tmpdir=$(mktemp -d)
  trap cleanup EXIT

  for entry in "${PATCHES[@]}"; do
    IFS='|' read -r feature releases lib what sig off new <<<"$entry"
    [[ -n ${wanted[$feature]-} ]] || continue
    # shellcheck disable=SC2053 # a pattern on purpose
    [[ $version == $releases ]] || continue
    apply_patch "$lib" "$what" "$sig" "$off" "$new"
    applied[$feature]=1
  done

  for feature in "${!wanted[@]}"; do
    [[ -n ${applied[$feature]-} ]] || die "no $feature patches for driver $version"
  done
}

main "$@"
