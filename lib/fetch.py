"""Download the tools in a manifest into a cache dir: fetch.py MANIFEST CACHE_DIR [--refresh]

Manifest lines: NAME URL [INSTALL ARGS...]  (# starts a comment)
URL may be "https://.../archive.zip!member" to fetch a single stored member
of a remote zip via HTTP range requests (e.g. one package out of a 1.2 GB
msixbundle) instead of the whole archive.

Each file is saved as CACHE_DIR/NAME.EXT. Existing files are kept unless
--refresh. Prints one status line per tool; exits 1 if any download failed.
"""
import os
import shutil
import struct
import sys
import urllib.request
import zlib

UA = "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"
CHUNK = 1 << 20


def request(url, start=None, end=None):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    if start is not None:
        req.add_header("Range", "bytes=%d-%s" % (start, "" if end is None else end))
    return urllib.request.urlopen(req, timeout=120)


def read_range(url, start, end):
    with request(url, start, end) as r:
        if r.status != 206:
            raise IOError("server ignores range requests")
        return r.read()


def copy(resp, out, total=None):
    done = 0
    while True:
        buf = resp.read(CHUNK)
        if not buf:
            break
        out.write(buf)
        done += len(buf)
        if total and sys.stderr.isatty():
            sys.stderr.write("\r    %d / %d MB" % (done >> 20, total >> 20))
    if total and sys.stderr.isatty():
        sys.stderr.write("\n")
    return done


def download(url, dest):
    with request(url) as r, open(dest, "wb") as out:
        copy(r, out, int(r.headers.get("Content-Length") or 0))


def download_member(url, member, dest):
    """Extract one member of a remote zip using range requests."""
    with request(url, 0, 0) as r:
        size = int(r.headers["Content-Range"].rsplit("/", 1)[1])
    tail = read_range(url, max(0, size - 65558), size - 1)  # EOCD + max comment
    eocd = tail.rfind(b"PK\x05\x06")
    if eocd < 0:
        raise IOError("not a zip archive")
    cd_size, cd_off = struct.unpack("<II", tail[eocd + 12:eocd + 20])
    entries, zip64 = None, False
    if cd_off == 0xFFFFFFFF:  # zip64: locate the zip64 end of central directory
        loc = tail.rfind(b"PK\x06\x07")
        (z64_off,) = struct.unpack("<Q", tail[loc + 8:loc + 16])
        rec = read_range(url, z64_off, z64_off + 55)
        cd_size, cd_off = struct.unpack("<QQ", rec[40:56])
        zip64 = True
    cd = read_range(url, cd_off, cd_off + cd_size - 1)
    pos = 0
    while pos < len(cd):
        (method, csize, usize, nlen, xlen, clen, loff) = (
            struct.unpack("<H", cd[pos + 10:pos + 12])[0],
            *struct.unpack("<II", cd[pos + 20:pos + 28]),
            *struct.unpack("<HHH", cd[pos + 28:pos + 34]),
            struct.unpack("<I", cd[pos + 42:pos + 46])[0])
        name = cd[pos + 46:pos + 46 + nlen].decode("utf-8", "replace")
        extra = cd[pos + 46 + nlen:pos + 46 + nlen + xlen]
        if name == member:
            if 0xFFFFFFFF in (csize, usize, loff):  # values live in the zip64 extra field
                vals = iter([])
                i = 0
                while i < len(extra):
                    tag, ln = struct.unpack("<HH", extra[i:i + 4])
                    if tag == 1:
                        vals = iter(struct.unpack("<%dQ" % (ln // 8), extra[i + 4:i + 4 + ln]))
                    i += 4 + ln
                if usize == 0xFFFFFFFF: usize = next(vals)
                if csize == 0xFFFFFFFF: csize = next(vals)
                if loff == 0xFFFFFFFF: loff = next(vals)
            break
        pos += 46 + nlen + xlen + clen
    else:
        raise IOError("%s not found in archive" % member)
    hdr = read_range(url, loff, loff + 29)  # local header: its name/extra lengths may differ
    nlen, xlen = struct.unpack("<HH", hdr[26:30])
    data_off = loff + 30 + nlen + xlen
    with request(url, data_off, data_off + csize - 1) as r, open(dest, "wb") as out:
        if method == 0:
            copy(r, out, csize)
        elif method == 8:
            d = zlib.decompressobj(-15)
            while True:
                buf = r.read(CHUNK)
                if not buf:
                    break
                out.write(d.decompress(buf))
            out.write(d.flush())
        else:
            raise IOError("unsupported compression method %d" % method)
    if os.path.getsize(dest) != usize:
        raise IOError("size mismatch")


def entries(manifest):
    with open(manifest) as f:
        for line in f:
            line = line.split("#", 1)[0].split()
            if len(line) >= 2:
                yield line[0], line[1]


def target(cache, name, url):
    path = url.split("!", 1)[1] if "!" in url else url.split("?", 1)[0]
    ext = os.path.splitext(path)[1] or ".bin"
    return os.path.join(cache, name + ext)


def main():
    args = [a for a in sys.argv[1:] if a != "--refresh"]
    if len(args) != 2:
        sys.exit(__doc__)
    manifest, cache = args
    refresh = "--refresh" in sys.argv
    os.makedirs(cache, exist_ok=True)
    failed = False
    for name, url in entries(manifest):
        dest = target(cache, name, url)
        if os.path.exists(dest) and not refresh:
            print("  cached   %s" % name)
            continue
        print("  download %s" % name, flush=True)
        part = dest + ".part"
        try:
            if "!" in url:
                download_member(*url.split("!", 1), part)
            else:
                download(url, part)
            shutil.move(part, dest)
        except Exception as e:  # keep going: one broken URL shouldn't block the rest
            failed = True
            print("  FAILED   %s: %s" % (name, e))
            if os.path.exists(part):
                os.remove(part)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
