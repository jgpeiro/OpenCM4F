"""Generates the fonts and icons of the OpenCM4F benchmark UI (anti-aliased, 4 bits per pixel).
From Sat Signal Lab; new icon set.

outputs:
  rtl/soc/rom/font_s.hex   small font  (96 glyphs, ASCII 32..127), (g * HS + row) * 12 + col, one 4-bit value per line
  rtl/soc/rom/font_l.hex   large font  (24 glyphs, see LARGE),       (g * HL + row) * 16 + col
  rtl/soc/rom/icons.hex    24 x 24 icons (7),                       (i * 24 + row) * 24 + col
  rtl/soc/rom/widths.hex   advance widths: small 0..95, large 96..127 (5 bits)
  fw/assets.h          widths, heights, large-font map and icon numbers for the firmware
  host/assets_data.h   all bitmaps for the C reference renderer (host/raster.c)
  tools/assets_preview.png
"""
import os, math
import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INTER = '/usr/share/fonts/opentype/inter/'
HS, HL = 15, 18          # rows of the small and the large font
STRIDE_S, STRIDE_L = 12, 16   # columns stored per glyph row

LARGE = ' 0123456789.-x'
assert len(LARGE) <= 14          # font_l in gpu.v: 14 glyphs


def render_font(path, size, chars, H, baseline, maxw, STRIDE):
    f0 = ImageFont.truetype(path, size)
    bm, widths = [], []
    tab = max(int(round(f0.getlength(d))) for d in '0123456789')     # tabular digits
    for ch in chars:
        f, sz = f0, size
        while f.getlength(ch) > maxw:          # shrink glyphs that would not fit the 16 columns
            sz -= 1
            f = ImageFont.truetype(path, sz)
        adv = f.getlength(ch)
        w = max(1, min(maxw, int(round(adv))))
        ox = 0
        if ch in '0123456789':
            ox = (tab - adv) / 2
            w = tab
        img = Image.new('L', (STRIDE + 8, H), 0)
        d = ImageDraw.Draw(img)
        # draw so that the baseline lands on row `baseline`
        d.text((ox, baseline), ch, font=f, fill=255, anchor='ls')
        a = np.array(img)[:, :STRIDE]
        if a[:, STRIDE - 1:].any() and STRIDE == 12:
            pass
        bm.append((a.astype(np.int32) * 15 + 127) // 255)
        widths.append(w)
    return np.array(bm), widths


def icon_canvas():
    S = 96
    img = Image.new('L', (S, S), 0)
    return img, ImageDraw.Draw(img), S


def finish(img):
    a = np.array(img.resize((24, 24), Image.BOX)).astype(np.int32)
    return (a * 15 + 127) // 255


def ic_gauge():
    img, d, S = icon_canvas()
    d.arc([6, 10, 90, 94], 150, 390, fill=255, width=10)
    d.line([(48, 52), (74, 26)], fill=255, width=9)
    d.ellipse([39, 43, 57, 61], fill=255)
    return finish(img)


def ic_bars():
    img, d, S = icon_canvas()
    for i, h in enumerate((40, 70, 52, 86)):
        x = 6 + i * 23
        d.rounded_rectangle([x, 92 - h, x + 16, 92], radius=3, fill=255)
    return finish(img)


def ic_stack():
    img, d, S = icon_canvas()
    for i, (a, b, c) in enumerate(((40, 30, 18), (20, 44, 24), (52, 20, 16))):
        y = 8 + i * 30
        d.rectangle([4, y, 4 + a, y + 20], fill=255)
        d.rectangle([8 + a, y, 8 + a + b, y + 20], fill=150)
        d.rectangle([12 + a + b, y, min(92, 12 + a + b + c), y + 20], fill=90)
    return finish(img)


def ic_bolt():
    img, d, S = icon_canvas()
    d.polygon([(58, 2), (14, 56), (44, 56), (34, 94), (82, 36), (52, 36)], fill=255)
    return finish(img)


def ic_chip():
    img, d, S = icon_canvas()
    d.rounded_rectangle([20, 20, 76, 76], radius=8, fill=255)
    d.rectangle([34, 34, 62, 62], fill=0)
    d.rectangle([40, 40, 56, 56], fill=255)
    for k in range(4):
        t = 27 + k * 14
        d.rectangle([t - 3, 4, t + 3, 20], fill=255)
        d.rectangle([t - 3, 76, t + 3, 92], fill=255)
        d.rectangle([4, t - 3, 20, t + 3], fill=255)
        d.rectangle([76, t - 3, 92, t + 3], fill=255)
    return finish(img)


def ic_play():
    img, d, S = icon_canvas()
    d.polygon([(22, 10), (84, 48), (22, 86)], fill=255)
    return finish(img)


def ic_check():
    img, d, S = icon_canvas()
    d.line([(14, 50), (38, 74), (84, 24)], fill=255, width=14, joint='curve')
    return finish(img)


ICONS = [('GAUGE', ic_gauge), ('BARS', ic_bars), ('STACK', ic_stack), ('BOLT', ic_bolt), ('CHIP', ic_chip),
         ('PLAY', ic_play), ('CHECK', ic_check)]
assert len(ICONS) <= 7


def main():
    os.makedirs(f'{ROOT}/rtl/soc/rom', exist_ok=True)
    os.makedirs(f'{ROOT}/fw', exist_ok=True)
    os.makedirs(f'{ROOT}/host', exist_ok=True)
    small_chars = [chr(c) for c in range(32, 128)]
    small_chars[127 - 32] = '°'            # code 127 = degree sign
    fs, ws = render_font(INTER + 'Inter-Medium.otf', 12, small_chars, HS, 11, 12, STRIDE_S)
    fl, wl = render_font(INTER + 'Inter-SemiBold.otf', 20, list(LARGE) + [' '] * (32 - len(LARGE)), HL, 16, 16,
                         STRIDE_L)
    fl = fl[:len(LARGE)]
    ic = np.array([f() for _, f in ICONS])

    def hexfile(name, arr):
        with open(f'{ROOT}/rtl/soc/rom/{name}', 'w') as fo:
            fo.write('\n'.join('%x' % v for v in arr.flatten()) + '\n')
    # the ROMs store glyph rows mirrored (column 15 - c): the RTL addresses them with ~col, so the
    # address does not go straight from a register into the block RAM (hold timing)
    hexfile('font_s.hex', fs[:, :, ::-1])
    hexfile('font_l.hex', fl[:, :, ::-1])
    hexfile('icons.hex', ic)
    print('large font glyphs', len(fl), 'icons', len(ic))
    hexfile('widths.hex', np.array(ws + wl))

    lmap = [0] * 256
    for i, ch in enumerate(LARGE):
        lmap[ord(ch)] = i
    with open(f'{ROOT}/fw/assets.h', 'w') as fo:
        fo.write('/* generated by tools/gen_assets.py */\n#pragma once\n')
        fo.write(f'#define FONT_S_H {HS}\n#define FONT_L_H {HL}\n#define FONT_S_STRIDE {STRIDE_S}\n#define DEG_SMALL 127\n')
        fo.write('static const unsigned char font_w[128] = {' + ','.join(map(str, ws + wl)) + '};\n')
        fo.write('static const unsigned char large_map[128] = {' + ','.join(map(str, lmap[:128])) + '};\n')
        for i, (n, _) in enumerate(ICONS):
            fo.write(f'#define IC_{n} {i}\n')
    with open(f'{ROOT}/host/assets_data.h', 'w') as fo:     # bitmaps for the C reference renderer
        fo.write('/* generated by tools/gen_assets.py */\n#pragma once\n')
        fo.write('static const unsigned char font_s_bm[] = {' + ','.join(map(str, fs.flatten())) + '};\n')
        fo.write('static const unsigned char font_l_bm[] = {' + ','.join(map(str, fl.flatten())) + '};\n')
        fo.write('static const unsigned char icon_bm[] = {' + ','.join(map(str, ic.flatten())) + '};\n')
    # preview
    prev = Image.new('L', (16 * 24 + 20, 200), 0)
    for i in range(96):
        prev.paste(Image.fromarray((fs[i] * 17).astype(np.uint8)), ((i % 24) * 16, (i // 24) * HS))
    for i in range(32):
        prev.paste(Image.fromarray((fl[i] * 17).astype(np.uint8)), ((i % 24) * 16, 70 + (i // 24) * HL)) if i < len(fl) else None
    for i in range(len(ICONS)):
        prev.paste(Image.fromarray((ic[i] * 17).astype(np.uint8)), (i * 25, 120))
    prev.resize((prev.width * 3, prev.height * 3), Image.NEAREST).save(f'{ROOT}/tools/assets_preview.png')
    os.system(f'python3 {ROOT}/tools/gen_init.py roms')
    print('small widths', ws[:20], 'large', wl[:16], 'icons', len(ICONS))


if __name__ == '__main__':
    main()
