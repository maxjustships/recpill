#!/usr/bin/env python3
"""Generate the RecPill red-dot icons: windows/rec.ico (16-256 px) and windows/rec.png (toast logo). Pure stdlib."""
import struct
import zlib
from pathlib import Path


def png(n):
    c = (n - 1) / 2
    r = n * 0.375
    rows = []
    for y in range(n):
        row = bytearray([0])
        for x in range(n):
            d = ((x - c) ** 2 + (y - c) ** 2) ** 0.5
            a = max(0.0, min(1.0, r - d + 0.5))
            row += bytes([225, 45, 45, int(a * 255)])
        rows.append(bytes(row))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", n, n, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b""))


here = Path(__file__).resolve().parent.parent
sizes = [256, 48, 32, 16]
imgs = [png(s) for s in sizes]
out = struct.pack("<HHH", 0, 1, len(sizes))
off = 6 + 16 * len(sizes)
for s, i in zip(sizes, imgs):
    out += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(i), off)
    off += len(i)
out += b"".join(imgs)
(here / "windows" / "rec.ico").write_bytes(out)
(here / "windows" / "rec.png").write_bytes(png(128))
(here / "linux" / "recpill.png").write_bytes(png(128))
print("icons written")
