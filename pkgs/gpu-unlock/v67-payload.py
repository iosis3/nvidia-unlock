"""Build the V67 SEC2 signature images that the unlock module boots.

Each image is the stack the SEC2 booter's overflow lands on: 64000 bytes of
0x0000019c filler with the gadget/PLM dwords patched in.  The offsets are Booter
addresses, so an image is only valid for the Booter release it was mined
against.  Constants and provenance are from Zagitta/gpu-unlock
(firmware/generate_v67.py): the GA10x chain credits WildFlash1st/cmp90hx-unlock's
rejoin15 patch for 610.43.03, the AD10x four-PLM chain credits
TOTORONG/AD103_win_unlocker (GPL-2.0-only).

    python3 pkgs/gpu-unlock/v67-payload.py OUTPUT_DIR
"""

import hashlib
import pathlib
import sys

SIZE = 0xFA00
FILL_DWORD = 0x0000019C

# offset: value, the write primitive at the end of the chain plus the PLM entry
# it opens; unnamed entries are stack words the return chain walks through.
GA10X = {
    0x1100: 0x00000007,
    0xF948: 0xFFFFFFFF,  # write value
    0xF950: 0x00000D44,
    0xF960: 0x00823804,  # FEAT_OVR_PLM address
    0xF968: 0x00001FCE,
    0xF974: 0x00000000,
    0xF97C: 0x00001101,
    0xF980: 0x000084C8,
    0xF984: 0x00008E18,
    0xF98C: 0x000084C8,
    0xF990: 0x00000000,
    0xF998: 0x00001FCE,
    0xF9A4: 0x0000FFBC,
    0xF9AC: 0x00005789,
    0xF9BC: 0x00000D44,
    0xF9CC: 0x00000003,
    0xF9D4: 0x00001FCE,
    0xF9E8: 0x00000D52,
    0xF9EC: 0x000081EE,
}

# AD10x: four PLM writes in one launch (WPR_CFG, FBPA, WPR, FEAT) plus an
# explicit SEC2 mailbox marker (0x67b00001) the module waits for.
AD10X = {
    0x1100: 0x00000007,
    0xF948: 0xFFFFF0FF,
    0xF950: 0x000021B2,
    0xF960: 0x001FA7CC,
    0xF968: 0x000033FC,
    0xF974: 0xFFFFFFFF,
    0xF97C: 0x0000256F,
    0xF980: 0x00007A02,
    0xF984: 0x009A0148,
    0xF98C: 0x000033FC,
    0xF998: 0xFFFFFFFF,
    0xF9A0: 0x0000256F,
    0xF9A4: 0x00007A02,
    0xF9A8: 0x001FA7C4,
    0xF9B0: 0x000033FC,
    0xF9BC: 0xFFFFFFFF,
    0xF9C4: 0x0000256F,
    0xF9C8: 0x00007A02,
    0xF9CC: 0x00823804,
    0xF9D4: 0x000033FC,
    0xF9E0: 0x67B00001,
    0xF9E8: 0x0000256F,
    0xF9EC: 0x00007A02,
    0xF9F8: 0x000031B5,
    0xF9FC: 0x0000771E,
}

PAYLOADS = {
    "v67-ga102-610.43.03.bin": (GA10X, "2a0aa1f86d0b6afff5214d641d87d46dc98ef06ed908ff05d0ddbad5ffb7e197"),
    "v67-ad102-610.43.03-four-plm.bin": (AD10X, "44c36b2d6b3424e53e18f3e55db85c833655de071ce66ce42749588a4a7dc8cb"),
}


def build(overrides: dict[int, int]) -> bytes:
    payload = bytearray(FILL_DWORD.to_bytes(4, "little") * (SIZE // 4))
    for offset, value in overrides.items():
        if offset % 4 or offset + 4 > SIZE:
            raise ValueError(f"override at 0x{offset:x} is not a dword inside the image")
        payload[offset : offset + 4] = value.to_bytes(4, "little")
    return bytes(payload)


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        raise SystemExit(f"usage: {sys.argv[0]} OUTPUT_DIR")
    output = pathlib.Path(argv[0])
    output.mkdir(parents=True, exist_ok=True)

    for name, (overrides, expected) in PAYLOADS.items():
        payload = build(overrides)
        digest = hashlib.sha256(payload).hexdigest()
        if digest != expected:
            raise ValueError(f"{name}: generated {digest}, not the published {expected}")
        (output / name).write_bytes(payload)
        print(f"{name}: {len(payload)} bytes, sha256 {digest[:16]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
