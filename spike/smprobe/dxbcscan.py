#!/usr/bin/env python3
"""dxbcscan: which DXIL operations a game's shaders use, read from its own files.

Finds DXBC containers (precompiled DirectX shaders) inside the files given, carves each one out,
disassembles them with the official dxc (`dxc.exe -dumpbin`, run under Wine in one cmd.exe batch),
and counts the shader models and the operations D3DMetal's converter refuses (spike/smprobe,
2026-10-08): dx.op.quadVote, dx.op.textureGatherRaw, dx.op.sampleCmpLevel, dx.op.textureStoreSample.
Text shader sources (.hlsl, .fx, .fxh) are grepped for the HLSL names instead. Zip archives are
read entry by entry (Forza Horizon 6 keeps its DXIL in media/ShadersDXIL.zip). Only the lines that
matter are kept from each disassembly (findstr in the batch), so a few thousand shaders cost little disk.

Usage:
  dxbcscan.py carve <out dir> <file or dir>...     carve the containers (<out>/<n>.dxil, index.txt)
  dxbcscan.py batch <out dir> <dxc dir unix> <out dir windows>   write <out>/dumpbin.bat for Wine
  dxbcscan.py count <out dir>                      read the <out>/*.txt disassemblies and summarise
  dxbcscan.py text <file or dir>...                grep HLSL sources for the four features
The three steps are separate because only the batch step needs Wine (run it with
`highball run <bottle> C:\\windows\\system32\\cmd.exe -- /c Z:\\...\\dumpbin.bat`).
"""
import os, re, struct, sys, collections, zipfile, io

MAGIC = b"DXBC"
OPS = ["dx.op.quadVote", "dx.op.textureGatherRaw", "dx.op.sampleCmpLevel", "dx.op.textureStoreSample"]
HLSL = [r"\bQuadAny\b", r"\bQuadAll\b", r"\bGatherRaw\b", r"\bSampleCmpLevel\b", r"\bRWTexture2DMS\b", r"\bRWTexture2DMSArray\b"]
MAX_FILE = 2 << 30   # skip files above 2 GB (packed assets, not shader packs)

def files_under(paths):
    for p in paths:
        if os.path.isdir(p):
            for root, dirs, names in os.walk(p):
                for n in names:
                    yield os.path.join(root, n)
        else:
            yield p

def containers(data):
    """Yield (offset, blob) for every plausible DXBC container in data."""
    i = 0
    while True:
        i = data.find(MAGIC, i)
        if i < 0 or i + 32 > len(data):
            return
        total, = struct.unpack_from("<I", data, i + 24)
        parts, = struct.unpack_from("<I", data, i + 28)
        ok = 64 <= total <= 16 << 20 and 1 <= parts <= 32 and i + total <= len(data)
        if ok:
            for k in range(parts):
                off, = struct.unpack_from("<I", data, i + 32 + 4 * k)
                if off + 8 > total:
                    ok = False; break
        if ok:
            yield i, data[i:i + total]
            i += total
        else:
            i += 4

def shader_model(blob):
    """(kind, major, minor) from the DXIL part's program header, or None."""
    parts, = struct.unpack_from("<I", blob, 28)
    for k in range(parts):
        off, = struct.unpack_from("<I", blob, 32 + 4 * k)
        if blob[off:off + 4] == b"DXIL":
            ver, = struct.unpack_from("<I", blob, off + 8)
            return ver >> 16, (ver >> 4) & 0xf, ver & 0xf
    return None

KINDS = {0: "ps", 1: "vs", 2: "gs", 3: "hs", 4: "ds", 5: "cs", 6: "lib", 7: "rg", 8: "is", 9: "ah", 10: "ch", 11: "ms", 12: "ca", 13: "ms", 14: "as"}

def blobs_in(f):
    """Yield (source name, offset, blob) for the containers in a file, looking inside zip archives."""
    try:
        size = os.path.getsize(f)
    except OSError:
        return
    if size < 64 or size > MAX_FILE:
        return
    if zipfile.is_zipfile(f):
        try:
            with zipfile.ZipFile(f) as z:
                for info in z.infolist():
                    if info.file_size < 64 or info.file_size > MAX_FILE:
                        continue
                    try:
                        data = z.read(info)
                    except Exception:
                        continue
                    for off, blob in containers(data):
                        yield f + "!" + info.filename, off, blob
            return
        except zipfile.BadZipFile:
            pass
    with open(f, "rb") as fh:
        data = fh.read()
    for off, blob in containers(data):
        yield f, off, blob

def carve(out, paths, limit=None):
    os.makedirs(out, exist_ok=True)
    n = 0; models = collections.Counter(); index = open(os.path.join(out, "index.txt"), "w")
    for f in files_under(paths):
        for src, off, blob in blobs_in(f):
            sm = shader_model(blob)
            if not sm:
                continue
            name = "%06d" % n; n += 1
            open(os.path.join(out, name + ".dxil"), "wb").write(blob)
            tag = "%s_%d_%d" % (KINDS.get(sm[0], str(sm[0])), sm[1], sm[2]); models[tag] += 1
            index.write("%s %s %d %d %s\n" % (name, tag, off, len(blob), src))
            if limit and n >= limit:
                break
        if limit and n >= limit:
            break
    index.close()
    print("%d DXIL containers carved into %s" % (n, out))
    for tag, c in sorted(models.items()):
        print("  %-10s %d" % (tag, c))

def batch(out, dxc_unix, out_win):
    w = lambda p: "Z:" + p.replace("/", "\\")
    names = sorted(x[:-5] for x in os.listdir(out) if x.endswith(".dxil"))
    keep = " ".join('/C:"%s"' % k for k in OPS + ["dx.shaderModel"])
    with open(os.path.join(out, "dumpbin.bat"), "w", newline="\r\n") as b:
        b.write("@echo off\n")
        for n in names:
            b.write('"%s\\dxc.exe" -dumpbin "%s\\%s.dxil" 2>&1 | findstr %s > "%s\\%s.txt"\n' % (w(dxc_unix), out_win, n, keep, out_win, n))
        b.write("echo dumpbin.bat done\n")
    print("%s/dumpbin.bat: %d disassemblies, only the lines naming the four ops and dx.shaderModel are kept" % (out, len(names)))

def count(out):
    index = {}
    for line in open(os.path.join(out, "index.txt")):
        name, tag, off, size, f = line.rstrip("\n").split(" ", 4)
        index[name] = (tag, f)
    per_op = collections.Counter(); per_op_models = collections.defaultdict(collections.Counter)
    hits = collections.defaultdict(list); scanned = 0; failed = 0
    for n, (tag, f) in sorted(index.items()):
        p = os.path.join(out, n + ".txt")
        if not os.path.exists(p):
            continue
        t = open(p, errors="replace").read(); scanned += 1
        if "dx.shaderModel" not in t:
            failed += 1; continue
        for op in OPS:
            c = len(re.findall(re.escape(op) + r"\.", t))
            if c:
                per_op[op] += 1; per_op_models[op][tag] += 1; hits[op].append((n, tag, c, f))
    print("%d disassemblies read, %d without a dx.shaderModel line (dumpbin failed)" % (scanned, failed))
    for op in OPS:
        print("%-28s in %d shaders  %s" % (op, per_op[op], dict(per_op_models[op])))
    for op in OPS:
        for n, tag, c, f in hits[op][:20]:
            print("  %s %s %s x%d  %s" % (op, n, tag, c, f))

def text(paths):
    total = collections.Counter(); files = collections.defaultdict(set)
    for f in files_under(paths):
        if not f.lower().endswith((".hlsl", ".fx", ".fxh", ".hlsli", ".h", ".inc", ".shader", ".txt")):
            continue
        try:
            t = open(f, errors="replace").read()
        except OSError:
            continue
        for pat in HLSL:
            c = len(re.findall(pat, t))
            if c:
                total[pat] += c; files[pat].add(f)
    for pat in HLSL:
        print("%-24s %5d uses in %d files" % (pat, total[pat], len(files[pat])))
        for f in sorted(files[pat])[:10]:
            print("    " + f)

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "carve" and len(sys.argv) > 3:
        limit = int(os.environ.get("DXBCSCAN_LIMIT", "0")) or None
        carve(sys.argv[2], sys.argv[3:], limit)
    elif cmd == "batch" and len(sys.argv) == 5: batch(sys.argv[2], sys.argv[3], sys.argv[4])
    elif cmd == "count" and len(sys.argv) == 3: count(sys.argv[2])
    elif cmd == "text" and len(sys.argv) > 2: text(sys.argv[2:])
    else: print(__doc__); sys.exit(1)
