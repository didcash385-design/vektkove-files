#!/usr/bin/env python3
"""Checks Vektkove encode/decode against Python's standard library and the reference zstd and lz4 libraries.

Usage: codec_test.py /path/to/vk-or-vkport [fuzz_iterations]
Optional references: pip install zstandard lz4
"""
import base64, binascii, codecs, gzip, html, json, os, quopri, random, subprocess, sys, urllib.parse, zlib

binary = sys.argv[1]
fuzz_iterations = int(sys.argv[2]) if len(sys.argv) > 2 else 200
random.seed(11)
failures = []
checks = 0

try:
    import zstandard
except ImportError:
    zstandard = None
try:
    import lz4.frame as lz4frame
except ImportError:
    lz4frame = None


def run(mode, fmt, data):
    result = subprocess.run([binary, mode, fmt, "-", "-"], input=data, capture_output=True)
    return result.returncode, result.stdout, result.stderr


def check(name, condition, detail=""):
    global checks
    checks += 1
    if not condition:
        failures.append(f"{name} {detail}")


def encode(fmt, data):
    code, out, err = run("encode", fmt, data)
    check(f"encode {fmt} exit", code == 0, err.decode(errors="replace")[:200])
    return out


def decode(fmt, data):
    code, out, err = run("decode", fmt, data)
    check(f"decode {fmt} exit", code == 0, err.decode(errors="replace")[:200])
    return out


B58 = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def b58encode(data):
    zeros = len(data) - len(data.lstrip(b"\0"))
    number = int.from_bytes(data, "big")
    out = bytearray()
    while number:
        number, rem = divmod(number, 58)
        out.append(B58[rem])
    return b"1" * zeros + bytes(reversed(out))


def corpus():
    samples = [b"", b"a", b"ab", b"abc", b"abcd", b"abcde", b"\0", b"\0\0\0\0", b"\0\0a", b"hello world", bytes(range(256))]
    for size in (7, 100, 1000, 5000, 70000, 300000):
        samples.append(os.urandom(size))
    samples.append(b"A" * 200000)
    samples.append((b"the quick brown fox jumps over the lazy dog. " * 3000))
    here = os.path.dirname(os.path.abspath(__file__))
    for name in ("vkport.c", "vkcodec.h", "../VKEngine.m", "../MANUAL.md"):
        try:
            with open(os.path.join(here, name), "rb") as handle:
                samples.append(handle.read())
        except OSError:
            pass
    skewed = bytes(random.choices(range(256), weights=[50 if i < 8 else 1 for i in range(256)], k=150000))
    samples.append(skewed)
    samples.append(bytes(random.choices(b"ab", k=40000)))
    return samples


samples = corpus()
skewed = samples[-2]
text_samples = [s for s in samples if len(s) < 6000]

# Text codecs against the standard library.
for data in text_samples:
    check("base64 encode", encode("base64", data) == base64.b64encode(data))
    check("base64 decode", decode("base64", base64.b64encode(data)) == data)
    check("base64 unpadded decode", decode("base64", base64.b64encode(data).rstrip(b"=")) == data)
    check("base64url encode", encode("base64url", data) == base64.urlsafe_b64encode(data).rstrip(b"="))
    check("base64url decode", decode("base64url", base64.urlsafe_b64encode(data)) == data)
    check("base32 encode", encode("base32", data) == base64.b32encode(data))
    check("base32 decode", decode("base32", base64.b32encode(data).lower()) == data)
    if hasattr(base64, "b32hexencode"):
        check("base32hex encode", encode("base32hex", data) == base64.b32hexencode(data))
        check("base32hex decode", decode("base32hex", base64.b32hexencode(data)) == data)
    check("hex encode", encode("hex", data) == binascii.hexlify(data))
    check("hex decode", decode("hex", binascii.hexlify(data).upper()) == data)
    check("base58 encode", encode("base58", data) == b58encode(data))
    check("base58 decode", decode("base58", b58encode(data)) == data)
    check("ascii85 encode", encode("ascii85", data) == base64.a85encode(data))
    check("ascii85 decode", decode("ascii85", base64.a85encode(data)) == data)
    check("ascii85 adobe decode", decode("ascii85", base64.a85encode(data, adobe=True)) == data)
    check("url encode", encode("url", data) == urllib.parse.quote_from_bytes(data, safe="").encode())
    check("url decode", decode("url", urllib.parse.quote_from_bytes(data, safe="").encode()) == data)
    check("rot13 roundtrip", decode("rot13", encode("rot13", data)) == data)
    check("rot47 roundtrip", decode("rot47", encode("rot47", data)) == data)
    check("binary roundtrip", decode("binary", encode("binary", data)) == data)
    check("qp roundtrip", decode("qp", encode("qp", data)) == data)
    check("qp python decode", quopri.decodestring(encode("qp", data)) == data.replace(b"\r\n", b"\n") or quopri.decodestring(encode("qp", data)) == data or b"\r" in data)
    check("urlform roundtrip", decode("urlform", encode("urlform", data)) == data)

check("rot13 text", encode("rot13", b"Hello, World!") == codecs.encode("Hello, World!", "rot13").encode())
check("html encode", encode("html", b"<a href=\"x\">T&C's</a>") == b"&lt;a href=&quot;x&quot;&gt;T&amp;C&#39;s&lt;/a&gt;")
check("html decode", decode("html", b"&lt;&#65;&#x42;&amp;&unknown;&nbsp;&#0;&#xD800;") == "<AB&&unknown;\u00a0&#0;&#xD800;".encode())
check("html python agree", decode("html", b"&lt;b&gt;&amp;&quot;") == html.unescape("&lt;b&gt;&amp;&quot;").encode())
unicode_text = "Hello, \u00e9\u4e2d\U0001F600 \"quoted\" \\ \n\t\x01 end".encode()
encoded = encode("json", unicode_text)
check("json encode", json.loads(b'"' + encoded + b'"') == unicode_text.decode() and all(c < 128 for c in encoded))
check("json decode", decode("json", json.dumps(unicode_text.decode())[1:-1].encode()) == unicode_text)
check("json decode surrogate pair", decode("json", b"\\ud83d\\ude00") == "\U0001F600".encode())
code, _, _ = run("decode", "json", b"\\ud83d")
check("json rejects lone surrogate", code != 0)
check("urlform plus", decode("urlform", b"a+b%20c") == b"a b c")
check("url keeps plus", decode("url", b"a+b") == b"a+b")
check("base64 whitespace", decode("base64", b"SGVs\nbG8g\r\nd29y bGQ=") == b"Hello world")
for bad_format, bad_data in [("base64", b"!!!!"), ("base64", b"AAAAA"), ("base64", b"AA=A"), ("base32", b"1"), ("hex", b"abc"), ("hex", b"zz"),
                             ("url", b"%zz"), ("url", b"%4"), ("binary", b"101"), ("base58", b"0OIl"), ("ascii85", b"vvvvv"), ("qp", b"=ZZ")]:
    code, _, _ = run("decode", bad_format, bad_data)
    check(f"{bad_format} rejects {bad_data!r}", code != 0)
code, _, err = run("decode", "nonsense", b"x")
check("unknown format", code != 0 and b"Unknown format" in err)

# Compression decoders against reference compressors.
for data in samples:
    for level in (0, 1, 6, 9):
        check(f"zlib decode level {level} size {len(data)}", decode("zlib", zlib.compress(data, level)) == data)
        check(f"gzip decode level {level} size {len(data)}", decode("gzip", gzip.compress(data, level)) == data)
    compressor = zlib.compressobj(6, zlib.DEFLATED, -15)
    check(f"deflate decode size {len(data)}", decode("deflate", compressor.compress(data) + compressor.flush()) == data)
    check("gzip multi-member", decode("gzip", gzip.compress(data[:100]) + gzip.compress(data[100:])) == data)
    if zstandard:
        for level in (1, 3, 9, 19, 22):
            for checksum in (False, True):
                frame = zstandard.ZstdCompressor(level=level, write_checksum=checksum).compress(data)
                check(f"zstd decode level {level} size {len(data)} sum {checksum}", decode("zstd", frame) == data)
        streamed = zstandard.ZstdCompressor(level=5).compressobj()
        frame = streamed.compress(data) + streamed.flush()
        check(f"zstd streamed (unknown content size) size {len(data)}", decode("zstd", frame) == data)
        check(f"zstd two frames size {len(data)}", decode("zstd", zstandard.ZstdCompressor().compress(data[:50]) + zstandard.ZstdCompressor().compress(data[50:])) == data)
    if lz4frame:
        for kwargs in ({}, {"block_size": lz4frame.BLOCKSIZE_MAX64KB}, {"content_checksum": True}, {"block_checksum": True, "block_linked": False},
                       {"block_linked": True, "compression_level": 9}, {"store_size": False}):
            check(f"lz4 decode {kwargs} size {len(data)}", decode("lz4", lz4frame.compress(data, **kwargs)) == data)

# Compression encoders read back by the reference libraries and by this tool.
for data in samples:
    for fmt, reader in (("zlib", zlib.decompress), ("gzip", gzip.decompress), ("deflate", lambda d: zlib.decompress(d, -15))):
        packed = encode(fmt, data)
        check(f"{fmt} reference read size {len(data)}", reader(packed) == data)
        check(f"{fmt} own roundtrip size {len(data)}", decode(fmt, packed) == data)
        if len(data) > 5000 and len(set(data)) < 100:
            check(f"{fmt} compresses repetitive data size {len(data)}", len(packed) < len(data) // 2)
    packed = encode("zstd", data)
    check(f"zstd own roundtrip size {len(data)}", decode("zstd", packed) == data)
    if zstandard:
        check(f"zstd reference read size {len(data)}", zstandard.ZstdDecompressor().decompress(packed, max_output_size=len(data) + 1) == data)
    packed = encode("lz4", data)
    check(f"lz4 own roundtrip size {len(data)}", decode("lz4", packed) == data)
    if lz4frame:
        check(f"lz4 reference read size {len(data)}", lz4frame.decompress(packed) == data)
        if len(data) > 5000:
            check(f"lz4 ratio near the reference size {len(data)}", len(packed) <= 1.5 * len(lz4frame.compress(data, compression_level=0)) + 64)

# Chains.
check("chain zstd+base64", decode("base64+zstd", encode("zstd+base64", b"chain me " * 50)) == b"chain me " * 50)
check("chain gzip+hex", decode("hex+gzip", encode("gzip+hex", b"x" * 1000)) == b"x" * 1000)
code, _, err = run("encode", "zstd", b"abc")
check("binary result allowed on the command line", code == 0)

# Corrupt and truncated streams must never crash or hang.
if zstandard and lz4frame:
    seeds = [("zstd", zstandard.ZstdCompressor(level=3, write_checksum=True).compress(samples[-3][:20000])),
             ("zstd", zstandard.ZstdCompressor(level=19).compress(samples[-5][:60000])),
             ("zstd", zstandard.ZstdCompressor(level=1).compress(skewed[:30000])),
             ("zlib", zlib.compress(samples[-3][:20000])), ("gzip", gzip.compress(samples[-3][:20000])),
             ("lz4", lz4frame.compress(samples[-3][:20000], content_checksum=True)), ("base64", base64.b64encode(os.urandom(300))),
             ("ascii85", base64.a85encode(os.urandom(300))), ("json", b"\\u00e9\\ud83d\\ude00 text"), ("html", b"&lt;&#x41;&amp;")]
    for iteration in range(fuzz_iterations):
        fmt, original = random.choice(seeds)
        mutated = bytearray(original)
        for _ in range(random.randint(1, 4)):
            if mutated:
                mutated[random.randrange(len(mutated))] = random.randrange(256)
        if random.random() < 0.3:
            mutated = mutated[:random.randrange(len(mutated) + 1)]
        try:
            result = subprocess.run([binary, "decode", fmt, "-", "-"], input=bytes(mutated), capture_output=True, timeout=30)
        except subprocess.TimeoutExpired:
            failures.append(f"fuzz {fmt} hang")
            continue
        checks += 1
        if result.returncode not in (0, 1) or b"AddressSanitizer" in result.stderr or b"runtime error" in result.stderr:
            failures.append(f"fuzz {fmt} crashed: {result.stderr[:300]!r}")

print(f"{checks} codec checks, {len(failures)} failures")
for failure in failures[:30]:
    print("FAIL", failure)
if not zstandard or not lz4frame:
    print("Note: install zstandard and lz4 for the reference comparisons.")
sys.exit(1 if failures else 0)
