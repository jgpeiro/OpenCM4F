"""Prints the bit patterns of Thumb instructions from an object file (llvm-objdump), for checking decoders.
usage: thumb_enc.py file.o"""
import subprocess, sys, re
out = subprocess.run(['llvm-objdump', '-d', '--triple=thumbv7em', '--mattr=+vfp4d16sp,+dsp', sys.argv[1]],
                     capture_output=True, text=True).stdout
for l in out.splitlines():
    m = re.match(r'\s+[0-9a-f]+:\s+([0-9a-f]{4})(?: ([0-9a-f]{4}))?\s+\t(.*)', l)
    if not m:
        continue
    def b(h):
        v = int(h, 16)
        return ' '.join(f'{(v >> s) & 15:04b}' for s in (12, 8, 4, 0))
    h2 = b(m.group(2)) if m.group(2) else ' ' * 19
    print(f'{b(m.group(1))} | {h2}  {m.group(3).replace(chr(9), " ")}')
