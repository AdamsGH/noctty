"""Convert the 32bpp top-down BMPs written by measure.ps1 to PNG (stdlib only).

usage: python -I bmp2png.py <in.bmp> <out.png> [top bottom]   # optional row crop
"""
import struct
import sys
import zlib


def main():
    src, dst = sys.argv[1], sys.argv[2]
    data = open(src, "rb").read()
    off = struct.unpack_from("<I", data, 10)[0]
    w, h = struct.unpack_from("<ii", data, 18)
    top_down = h < 0
    h = abs(h)
    rows = []
    for y in range(h):
        row = data[off + y * w * 4: off + (y + 1) * w * 4]
        rows.append(row)
    if not top_down:
        rows.reverse()
    top, bottom = 0, h
    if len(sys.argv) >= 5:
        top, bottom = int(sys.argv[3]), min(h, int(sys.argv[4]))
    raw = bytearray()
    for y in range(top, bottom):
        row = rows[y]
        raw.append(0)
        out = bytearray(len(row) // 4 * 3)
        out[0::3] = row[2::4]
        out[1::3] = row[1::4]
        out[2::3] = row[0::4]
        raw += out

    def chunk(tag, payload):
        c = struct.pack(">I", len(payload)) + tag + payload
        return c + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, bottom - top, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    png += chunk(b"IEND", b"")
    open(dst, "wb").write(png)


main()
