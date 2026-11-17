"""Screenshots for the docs from a raw frame capture of tb_soc (RGB565, 480 x 272):
  shots.py <frames.raw> grid <out.png> i0 i1 i2 i3 ...   frames side by side, two per row
  shots.py <frames.raw> gif <out.gif> first last [step] [ms]
"""
import sys
import numpy as np
from PIL import Image

fr = np.fromfile(sys.argv[1], np.uint16).reshape(-1, 272, 480).astype(np.uint32)


def rgb(f):
    return Image.fromarray(np.stack([((f >> 11) & 31) * 255 // 31, ((f >> 5) & 63) * 255 // 63,
                                     (f & 31) * 255 // 31], -1).astype(np.uint8))


mode, out = sys.argv[2], sys.argv[3]
if mode == 'grid':
    idx = [int(x) for x in sys.argv[4:]]
    cols = 2 if len(idx) > 1 else 1
    rows = (len(idx) + cols - 1) // cols
    g = Image.new('RGB', (480 * cols + 8 * (cols - 1), 272 * rows + 8 * (rows - 1)), (40, 40, 40))
    for k, i in enumerate(idx):
        g.paste(rgb(fr[i]), ((k % cols) * 488, (k // cols) * 280))
    g.save(out)
else:
    a, b = int(sys.argv[4]), int(sys.argv[5])
    step = int(sys.argv[6]) if len(sys.argv) > 6 else 1
    ms = int(sys.argv[7]) if len(sys.argv) > 7 else 120
    ims = [rgb(fr[i]).quantize(colors=128, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
           for i in range(a, min(b, len(fr)), step)]
    ims[0].save(out, save_all=True, append_images=ims[1:], duration=ms, loop=0, optimize=True)
print(len(fr), 'frames in the capture')
