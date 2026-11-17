"""raw RGB565 frames -> PNG (one frame) or GIF; usage: frames.py in.raw out.png|out.gif [index] [scale]"""
import sys
import numpy as np
from PIL import Image
fr = np.fromfile(sys.argv[1], np.uint16).reshape(-1, 272, 480).astype(np.uint32)
def rgb(f):
    return Image.fromarray(np.stack([((f >> 11) & 31) * 255 // 31, ((f >> 5) & 63) * 255 // 63, (f & 31) * 255 // 31], -1).astype(np.uint8))
scale = int(sys.argv[4]) if len(sys.argv) > 4 else 1
if sys.argv[2].endswith('.png'):
    im = rgb(fr[int(sys.argv[3]) if len(sys.argv) > 3 else -1])
    im.resize((480 * scale, 272 * scale), Image.LANCZOS if scale < 1 else Image.NEAREST).save(sys.argv[2])
else:
    ims = [rgb(f).quantize(colors=200, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE) for f in fr]
    ims[0].save(sys.argv[2], save_all=True, append_images=ims[1:], duration=int(sys.argv[3]) if len(sys.argv) > 3 else 70, loop=0, optimize=True)
print(len(fr), 'frames')
