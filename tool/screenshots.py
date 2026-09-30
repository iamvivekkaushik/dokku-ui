#!/usr/bin/env python3
"""Renders the README screenshots into docs/screenshots.

The pictures come from test/screenshots, which draws every screen with the
Dokku output captured in test/support, then they are shrunk to a 256-colour
palette, which loses nothing visible on this flat, dark interface and makes
the files a third of the size.

Run from the project root:  python3 tool/screenshots.py
Needs Flutter on the path and Pillow (pip install pillow).
"""

import os
import subprocess
import sys
from PIL import Image

OUT = 'docs/screenshots'


def render():
    env = {**os.environ, 'SCREENSHOTS': OUT}
    subprocess.run(['flutter', 'test', 'test/screenshots'], env=env, check=True)


def shrink(path):
    before = os.path.getsize(path)
    image = Image.open(path).convert('RGB')
    image.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE).save(path, optimize=True)
    print(f'{before // 1024:>5} -> {os.path.getsize(path) // 1024:>4} KB  {path}')


def main():
    if not os.path.isdir('test/screenshots'):
        sys.exit('run this from the project root')
    render()
    for name in sorted(os.listdir(OUT)):
        if name.endswith('.png'):
            shrink(os.path.join(OUT, name))


if __name__ == '__main__':
    main()
