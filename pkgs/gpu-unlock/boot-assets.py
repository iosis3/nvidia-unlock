"""Derive the SEC2 Booter and GSP boot assets for the GPU unlock.

The open kernel module source tree ships the Booter and GSP boot images as
generated C byte arrays.  The V67 signature chain that the unlock module boots
is mined against one specific Booter, so the assets are verified against the
hashes of the build the chain was made for: the GA102 Booter, GSP boot image and
bootloader descriptor of 610.43.03, which are byte-identical in 615.71.09.

Both bindata formats are supported: 610 releases emit one token per byte, 615
and later emit 0x...ULL words with the array padded to the element width.

    python3 pkgs/gpu-unlock/boot-assets.py SOURCE_ROOT OUTPUT_DIR
"""

import hashlib
import pathlib
import re
import struct
import sys
import zlib

GENERATED = "src/nvidia/generated"

# The builds the V67 chains were mined against; gpu-unlock's
# firmware/artifacts-610.43.03.json lists the same digests.  610.43.03 routes
# every AD10x part (AD102/103/104/106/107) through the same AD102 Booter.
EXPECTED = {
    # arch: (BooterLoad source, GspRmBoot source, digests)
    "ga102": (
        "g_bindata_kgspGetBinArchiveBooterLoadUcode_GA102.c",
        "g_bindata_kgspGetBinArchiveGspRmBoot_GA102.c",
        {
            "booter_load_ga102.bin": "056cbc064a888f80717726c54d7f64fcd68044d123870c95a74f37f4975dcaa4",
            "gsp_boot_ga102.bin": "3df651acb174fd5f5561a1996965b192f50c5d763168446ed0d4ead19d895768",
            "gsp_boot_desc_ga102.bin": "cc5a3fc1f4c47f2fe107b1b68f0176d8a448e6dec84b575e5560ccef5262bf15",
        },
    ),
    "ad102": (
        "g_bindata_kgspGetBinArchiveBooterLoadUcode_AD102.c",
        "g_bindata_kgspGetBinArchiveGspRmBoot_AD102.c",
        {
            "booter_load_ad102.bin": "6ee05b20e1dc244c08c052f36ef28469b8d09f4955d1fe33e48a179e11a7fd49",
            "gsp_boot_ad102.bin": "45d6335a8185d6ff13e8d1484cea73f68d3d13aa1c19dc080ed1c3482dd5bac0",
            "gsp_boot_desc_ad102.bin": "83f8f3f1f5f9496e0ea8fc7103c2beb64d0b6de2f5ffe725f13514de5a95fa42",
        },
    ),
}

BOOTER_MAGIC = 0x314C5442  # "BTL1" in the module's loader


def array_bytes(text: str, label: str) -> bytes:
    marker = f"BINDATA_LABEL_{label}_data[]"
    if text.count(marker) != 1:
        raise ValueError(f"{label}: expected one declaration, found {text.count(marker)}")

    start = text.index(marker)
    block = text[text.rindex("// FUNCTION:", 0, start) : start]
    compressed = re.search(r"COMPRESSION: (YES|NO)", block).group(1) == "YES"
    size = int(re.search(r"DATA SIZE \(bytes\): (\d+)", block).group(1))

    declaration = re.match(re.escape(marker) + r"\s*=\s*\{(.*?)\};", text[start:], re.S)
    if declaration is None:
        raise ValueError(f"{label}: malformed declaration")

    raw = bytearray()
    for token in (t.strip() for t in declaration.group(1).split(",")):
        if not token:
            continue
        match = re.fullmatch(r"0x([0-9a-fA-F]+)(?:ULL|UL|U|LL)?", token)
        if match is None:
            raise ValueError(f"{label}: unexpected token {token[:32]!r}")
        digits = match.group(1)
        raw += int(digits, 16).to_bytes(len(digits) // 2, "little")
    raw = bytes(raw)

    if compressed:
        inflater = zlib.decompressobj(-15)
        data = inflater.decompress(raw)
        if not inflater.eof:
            raise ValueError(f"{label}: truncated deflate stream")
        trailer = inflater.unused_data
        # NVIDIA appends the gzip CRC32/ISIZE without the gzip header; newer
        # releases pad the array to the element width with zeros after it.
        if len(trailer) < 8 or any(trailer[8:]):
            raise ValueError(f"{label}: unexpected deflate trailer")
        crc, stored = struct.unpack("<II", trailer[:8])
        if stored != size or crc != zlib.crc32(data):
            raise ValueError(f"{label}: deflate checksum mismatch")
    else:
        if not size <= len(raw) < size + 8:
            raise ValueError(f"{label}: {len(raw)} bytes for a declared {size}")
        data = raw[:size]

    if len(data) != size:
        raise ValueError(f"{label}: inflated {len(data)} bytes, header says {size}")
    return data


def booter_bundle(text: str) -> bytes:
    """Rebuild the BooterLoad record the module hands to the SEC2 Falcon."""
    image = array_bytes(text, "IMAGE_PROD")
    header = array_bytes(text, "HEADER_PROD")
    signatures = array_bytes(text, "SIG_PROD")
    patch_loc = array_bytes(text, "PATCH_LOC")
    patch_meta = array_bytes(text, "PATCH_META")
    num_sigs = array_bytes(text, "NUM_SIGS")

    if len(header) != 36 or len(patch_loc) != 4 or len(patch_meta) != 12 or len(num_sigs) != 4:
        raise ValueError("unexpected BooterLoad record size")

    fields = struct.unpack("<9I", header)
    location = struct.unpack("<I", patch_loc)[0]
    _fuse, engine, ucode = struct.unpack("<3I", patch_meta)
    count = struct.unpack("<I", num_sigs)[0]

    if not count or len(signatures) != count * 384 or fields[4] != 1 or not ucode:
        raise ValueError("unsupported Booter signature/application table")
    if not fields[2] <= location and location + 384 <= fields[2] + fields[3]:
        raise ValueError("signature patch is outside the DMEM image")
    if fields[2] + fields[3] > len(image):
        raise ValueError("DMEM image shorter than its declared range")
    for offset, size in ((fields[0], fields[1]), (fields[2], fields[3]), (fields[5], fields[6])):
        if offset + size > len(image) or offset % 256 or size % 256:
            raise ValueError("invalid Falcon transfer range")

    header_out = struct.pack(
        "<14I",
        *fields[:9],
        location,
        ucode,
        engine,
        count,
        len(signatures),
    )
    prefix = struct.pack("<II", BOOTER_MAGIC, 1) + header_out + struct.pack("<II", len(image), len(signatures))
    return prefix + image + signatures


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} SOURCE_ROOT OUTPUT_DIR")
    source, output = map(pathlib.Path, argv)
    generated = source / GENERATED
    output.mkdir(parents=True, exist_ok=True)

    for arch, (booter_file, boot_file, digests) in EXPECTED.items():
        booter = booter_bundle((generated / booter_file).read_text())
        boot = (generated / boot_file).read_text()
        assets = {
            f"booter_load_{arch}.bin": booter,
            f"gsp_boot_{arch}.bin": array_bytes(boot, "UCODE_IMAGE_PROD"),
            f"gsp_boot_desc_{arch}.bin": array_bytes(boot, "UCODE_DESC_PROD"),
        }
        if len(assets[f"gsp_boot_desc_{arch}.bin"]) != 84:
            raise ValueError(f"{arch}: unexpected bootloader descriptor length")

        for name, data in assets.items():
            digest = hashlib.sha256(data).hexdigest()
            if digest != digests[name]:
                raise ValueError(
                    f"{name}: {digest} is not the build its V67 chain targets "
                    f"({digests[name]}); the payload would not match this Booter"
                )
            (output / name).write_bytes(data)
            print(f"{name}: {len(data)} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
