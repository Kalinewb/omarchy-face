#!/usr/bin/env python3
"""Compare two PNGs pixel by pixel, in premultiplied RGBA (what is drawn).

    png-diff.py a.png b.png        prints: <size> <pixels that differ> <max channel difference>

Used by dev/e2-hosting.sh. ImageMagick's own AE metric counts fractions on
translucent pixels, and a difference in the unpremultiplied colour of a pixel
whose alpha is 4 of 255 is not a difference anybody can see, so the comparison
is made on what the compositor adds up: colour times alpha.
"""
import subprocess
import sys

import numpy as np


def load(path):
    size = subprocess.run(["magick", "identify", "-format", "%w %h", path],
                          capture_output=True, check=True).stdout.split()
    width, height = int(size[0]), int(size[1])
    raw = subprocess.run(["magick", path, "-depth", "8", "rgba:-"],
                         capture_output=True, check=True).stdout
    image = np.frombuffer(raw, dtype=np.uint8).reshape(height, width, 4).astype(float)
    image[..., :3] *= image[..., 3:4] / 255.0
    return image


a, b = load(sys.argv[1]), load(sys.argv[2])
if a.shape != b.shape:
    print(f"{a.shape[1]}x{a.shape[0]} vs {b.shape[1]}x{b.shape[0]} -1 -1")
    sys.exit(0)
diff = np.abs(a - b)
print(f"{a.shape[1]}x{a.shape[0]} {int((diff.max(axis=2) > 0.5).sum())} {diff.max():.1f}")
