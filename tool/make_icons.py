#!/usr/bin/env python3
"""Draws the launcher icons for every platform from the app's "dk" mark.

Run from the project root after changing the mark:  python3 tool/make_icons.py
Needs Pillow (pip install pillow).
"""

import json
import os
from PIL import Image, ImageDraw, ImageFont

INK = (10, 10, 11, 255)  # C.bg
PAPER = (237, 237, 239, 255)  # C.fg
FONT = 'assets/fonts/GeistMono-Medium.ttf'
SS = 4  # drawn larger, then scaled down, so edges come out smooth


def tile(size):
    """The mark itself: a light rounded square with "dk" on it."""
    s = size * SS
    img = Image.new('RGBA', (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((0, 0, s - 1, s - 1), radius=round(s * 0.27), fill=PAPER)
    font = ImageFont.truetype(FONT, round(s * 0.46))
    d.text((s / 2, s * 0.49), 'dk', font=font, fill=INK, anchor='mm')
    return img


def icon(size, *, mark=0.58, plate=1.0, radius=0.0, background=INK):
    """The mark centred on a plate. `plate` and `mark` are fractions of `size`."""
    s = size * SS
    img = Image.new('RGBA', (s, s), (0, 0, 0, 0))
    if background is not None:
        p = round(s * plate)
        o = (s - p) // 2
        ImageDraw.Draw(img).rounded_rectangle((o, o, o + p - 1, o + p - 1), radius=round(p * radius), fill=background)
    m = tile(round(size * mark))
    img.alpha_composite(m, ((s - m.width) // 2, (s - m.height) // 2))
    return img.resize((size, size), Image.LANCZOS)


def save(img, path, opaque=False):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if opaque:
        img = img.convert('RGB')
    img.save(path, optimize=True)
    print(f'{img.width:>5} {path}')


def main():
    # Android: legacy icons, plus an adaptive icon the launcher masks itself.
    for density, scale in {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}.items():
        res = 'android/app/src/main/res'
        save(icon(round(48 * scale), plate=0.92, radius=0.24, mark=0.54), f'{res}/mipmap-{density}/ic_launcher.png')
        save(icon(round(108 * scale), mark=0.36, background=None), f'{res}/mipmap-{density}/ic_launcher_foreground.png')

    # iOS wants opaque squares and rounds the corners itself.
    ios = 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
    for entry in json.load(open(f'{ios}/Contents.json'))['images']:
        points = float(entry['size'].split('x')[0])
        pixels = round(points * int(entry['scale'].rstrip('x')))
        save(icon(pixels), f"{ios}/{entry['filename']}", opaque=True)

    # macOS icons carry their own rounded plate and margin.
    mac = 'macos/Runner/Assets.xcassets/AppIcon.appiconset'
    for size in (16, 32, 64, 128, 256, 512, 1024):
        save(icon(size, plate=0.82, radius=0.225, mark=0.48), f'{mac}/app_icon_{size}.png')

    # Windows keeps every size in one file.
    big = icon(256, plate=1, radius=0.22, mark=0.6)
    big.save('windows/runner/resources/app_icon.ico', sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (256, 256)])
    print('  ico windows/runner/resources/app_icon.ico')


if __name__ == '__main__':
    main()
