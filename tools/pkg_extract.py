"""Extract a macOS .pkg (XAR -> gzip/pbzx cpio payloads) using only the standard library.

usage: py -I pkg_extract.py <file.pkg> <out_dir>
Symlinks are not created (Windows); they are listed in <out_dir>/_symlinks.txt.
Every path is listed in <out_dir>/_files.txt.
"""
import lzma, os, struct, sys, zlib
import xml.etree.ElementTree as ET

CHUNK = 1 << 20


def xar_entries(f):
    magic, hsize, _ver, toc_c, toc_u, _ck = struct.unpack(">4sHHQQI", f.read(28))
    if magic != b"xar!":
        sys.exit("not a xar archive")
    f.seek(hsize)
    toc = zlib.decompress(f.read(toc_c))
    heap = hsize + toc_c
    root = ET.fromstring(toc)

    def walk(node, prefix):
        for fe in node.findall("file"):
            name = fe.findtext("name")
            path = prefix + "/" + name if prefix else name
            data = fe.find("data")
            if data is not None:
                yield path, heap + int(data.findtext("offset")), int(data.findtext("length")), \
                    data.find("encoding").get("style")
            yield from walk(fe, path)

    yield from walk(root.find("toc"), "")


def raw_chunks(f, off, length):
    f.seek(off)
    left = length
    while left:
        b = f.read(min(CHUNK, left))
        if not b:
            raise EOFError("truncated heap")
        left -= len(b)
        yield b


def decoded(f, off, length, style):
    """xar-level encoding (usually none for Payload), then the payload's own compression."""
    src = raw_chunks(f, off, length)
    if "gzip" in style or "zlib" in style:
        d = zlib.decompressobj(47)
        src = (d.decompress(b) for b in src)
    buf = bytearray()
    it = iter(src)
    for b in it:
        buf += b
        if len(buf) >= 4:
            break
    head = bytes(buf[:4])
    rest = it
    if head[:2] == b"\x1f\x8b":
        d = zlib.decompressobj(47)
        yield d.decompress(bytes(buf))
        for b in rest:
            yield d.decompress(b)
        yield d.flush()
    elif head == b"pbzx":
        yield from pbzx(bytes(buf), rest)
    else:
        yield bytes(buf)
        yield from rest


def pbzx(first, rest):
    r = Reader(iter([first, *[]]), rest)
    r.read(4)
    r.read(8)  # flags
    while True:
        hdr = r.read(16, eof_ok=True)
        if not hdr:
            return
        _flags, size = struct.unpack(">QQ", hdr)
        blob = r.read(size)
        yield lzma.decompress(blob) if blob[:6] == b"\xfd7zXZ\x00" else blob


class Reader:
    def __init__(self, *iters):
        self.iters = list(iters)
        self.buf = bytearray()
        self.pos = 0

    def _fill(self, n):
        while len(self.buf) - self.pos < n and self.iters:
            b = next(self.iters[0], None)
            if b is None:
                self.iters.pop(0)
                continue
            if self.pos > CHUNK:
                del self.buf[:self.pos]
                self.pos = 0
            self.buf += b

    def read(self, n, eof_ok=False):
        self._fill(n)
        out = bytes(self.buf[self.pos:self.pos + n])
        self.pos += len(out)
        if len(out) < n and not (eof_ok and not out):
            raise EOFError("short read")
        return out

    def copy_to(self, n, out):
        while n:
            self._fill(1)
            take = min(n, len(self.buf) - self.pos)
            if not take:
                raise EOFError("short file body")
            if out:
                out.write(self.buf[self.pos:self.pos + take])
            self.pos += take
            n -= take


def safe_join(base, name):
    parts = [p for p in name.replace("\\", "/").split("/") if p not in ("", ".")]
    if any(p == ".." or ":" in p for p in parts):
        raise ValueError("unsafe path in archive: " + name)
    return os.path.join(base, *parts) if parts else None


def cpio_extract(chunks, out, files_log, links_log):
    r = Reader(chunks)
    n = 0
    while True:
        magic = r.read(6)
        if magic == b"070707":
            h = r.read(70)
            mode = int(h[12:18], 8)
            namesize = int(h[53:59], 8)
            fsize = int(h[59:70], 8)
            name = r.read(namesize)[:-1].decode("utf-8", "replace")
            pad_name = pad_body = 0
        elif magic in (b"070701", b"070702"):
            h = r.read(104)
            fld = [int(h[i:i + 8], 16) for i in range(0, 104, 8)]
            mode, fsize, namesize = fld[1], fld[6], fld[11]
            name = r.read(namesize)[:-1].decode("utf-8", "replace")
            pad_name = (4 - (110 + namesize) % 4) % 4
            pad_body = (4 - fsize % 4) % 4
        else:
            raise ValueError("bad cpio magic %r" % magic)
        r.read(pad_name)
        if name == "TRAILER!!!":
            return n
        kind = mode & 0o170000
        dest = safe_join(out, name)
        if kind == 0o120000:
            target = r.read(fsize).decode("utf-8", "replace")
            links_log.write(f"{name} -> {target}\n")
        elif kind == 0o040000:
            if dest:
                os.makedirs(dest, exist_ok=True)
            r.copy_to(fsize, None)
        else:
            files_log.write(f"{fsize}\t{oct(mode & 0o777)}\t{name}\n")
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "wb") as fh:
                r.copy_to(fsize, fh)
            n += 1
        r.read(pad_body)


def main():
    pkg, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    with open(pkg, "rb") as f, \
            open(os.path.join(out, "_files.txt"), "w", encoding="utf-8") as fl, \
            open(os.path.join(out, "_symlinks.txt"), "w", encoding="utf-8") as ll:
        entries = list(xar_entries(f))
        for path, off, length, style in entries:
            print(f"xar: {path} ({length:,} bytes, {style})")
        for path, off, length, style in entries:
            leaf = path.rsplit("/", 1)[-1]
            if leaf in ("Payload", "Scripts"):  # GOG puts the game in Scripts
                sub = os.path.join(out, (path.rsplit("/", 1)[0] if "/" in path else "root") + "-" + leaf)
                print("extracting", path, "->", sub, flush=True)
                n = cpio_extract(decoded(f, off, length, style), sub, fl, ll)
                print(f"  {n} files")
            elif leaf in ("Distribution", "PackageInfo", "Bom") or path.endswith(".plist"):
                dest = safe_join(out, "_meta/" + path)
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                with open(dest, "wb") as fh:
                    for b in decoded(f, off, length, style):
                        fh.write(b)


if __name__ == "__main__":
    main()
