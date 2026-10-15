"""MEASUREMENT ONLY (PKG-73b): name module+0xoffset frames by nearest export.

usage: python -I pe_exports.py <module.dll> <hex offset> [more offsets]
Reads C:\\Windows\\System32\\<module> (or nvoglv64 from the driver store
when given a full path) and prints the nearest export at or below each RVA.
"""
import pathlib
import struct
import sys


def exports(path):
    b = pathlib.Path(path).read_bytes()
    pe = struct.unpack_from("<I", b, 0x3C)[0]
    nsec = struct.unpack_from("<H", b, pe + 6)[0]
    opt = pe + 24
    optsz = struct.unpack_from("<H", b, pe + 20)[0]
    exp_rva = struct.unpack_from("<I", b, opt + 112)[0]
    secs = []
    for i in range(nsec):
        o = opt + optsz + i * 40
        va, vsz, raw = struct.unpack_from("<III", b, o + 12)[0], struct.unpack_from("<I", b, o + 8)[0], struct.unpack_from("<I", b, o + 20)[0]
        secs.append((va, vsz, raw))

    def off(rva):
        for va, vsz, raw in secs:
            if va <= rva < va + max(vsz, 1):
                return rva - va + raw
        raise ValueError(rva)

    e = off(exp_rva)
    nfun, nnames, afun, anames, aord = struct.unpack_from("<IIIII", b, e + 20)
    funcs = [struct.unpack_from("<I", b, off(afun) + 4 * i)[0] for i in range(nfun)]
    out = []
    for i in range(nnames):
        nrva = struct.unpack_from("<I", b, off(anames) + 4 * i)[0]
        ordi = struct.unpack_from("<H", b, off(aord) + 2 * i)[0]
        name = b[off(nrva):b.index(b"\0", off(nrva))].decode()
        out.append((funcs[ordi], name))
    return sorted(out)


mod = sys.argv[1]
path = mod if "\\" in mod or "/" in mod else rf"C:\Windows\System32\{mod}"
ex = exports(path)
for h in sys.argv[2:]:
    rva = int(h, 16)
    best = max((x for x in ex if x[0] <= rva), default=None)
    print(f"{mod}+{h} = {best[1]}+0x{rva - best[0]:x}" if best else f"{mod}+{h} = ?")
