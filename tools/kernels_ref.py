"""Reference results of the firmware's SHA-256 and CRC-32 benchmarks (fw/bm_kernels.c), printed as
compiler flags: -DSHA_REF=... -DCRC_REF=...  (the 1 KB message comes from the same LCG as the firmware)"""
import hashlib, zlib
s, msg = 1, bytearray()
for i in range(1024):
    s = (s * 1664525 + 1013904223) & 0xFFFFFFFF
    msg.append(s >> 24)
d = hashlib.sha256(bytes(msg)).digest()
words = ','.join('0x%08xu' % int.from_bytes(d[4 * i:4 * i + 4], 'big') for i in range(8))
c = 0
for k in range(4):
    c = zlib.crc32(bytes(msg), c)
print(f"'-DSHA_REF={words}' -DCRC_REF=0x{c:08x}u")
