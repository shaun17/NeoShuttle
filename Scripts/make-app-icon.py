#!/usr/bin/env python3
# Usage: python3 Scripts/make-app-icon.py [source.png] [AppIcon.appiconset]
# Needs Pillow and numpy.
"""Turns the rounded-square icon into a full-bleed square so macOS applies its own mask.

Keeps the rocket, flame and their shadows from the original; redraws the background
as a smooth surface fitted to the original's shading, out to every edge.
"""
from PIL import Image, ImageFilter
import numpy as np, sys

import json, os

src = sys.argv[1] if len(sys.argv) > 1 else 'Branding/app-icon-source.png'
iconset = sys.argv[2] if len(sys.argv) > 2 else 'Sources/NeoShuttle/Assets.xcassets/AppIcon.appiconset'
im = Image.open(src).convert('RGBA')
arr = np.asarray(im).astype(np.float64)
a, rgb = arr[..., 3], arr[..., :3]
solid = a > 250
ys, xs = np.nonzero(solid)
body = (xs.min(), ys.min(), xs.max() + 1, ys.max() + 1)

def image(mask):
    return Image.fromarray((mask * 255).astype(np.uint8))

def inset(mask, pixels):
    return np.asarray(image(mask).filter(ImageFilter.MinFilter(pixels * 2 + 1))) > 0

def design(x, y):
    x, y = x / 1254.0, y / 1254.0
    return np.stack([np.ones_like(x), x, y, x*x, x*y, y*y, x**3, x*x*y, x*y*y, y**3], axis=-1)

lum, sat = rgb.mean(axis=2), rgb.max(axis=2) - rgb.min(axis=2)
background = inset(solid, 60) & (lum < 100) & (sat < 12)
Y, X = np.nonzero(background)
A = design(X.astype(float), Y.astype(float))
coef = [np.linalg.lstsq(A, rgb[Y, X, c], rcond=None)[0] for c in range(3)]
gy, gx = np.mgrid[0:a.shape[0], 0:a.shape[1]].astype(float)
fill = np.stack([design(gx, gy) @ coef[c] for c in range(3)], axis=-1)

foreground = (np.abs(rgb - fill).mean(axis=2) > 9) & inset(solid, 90)
mask = (image(foreground)
        .filter(ImageFilter.MinFilter(7)).filter(ImageFilter.MaxFilter(7))   # drop specks
        .filter(ImageFilter.MaxFilter(15)).filter(ImageFilter.GaussianBlur(7)))  # take soft edges along
alpha = np.asarray(mask).astype(float)[..., None] / 255
out = rgb * alpha + fill * (1 - alpha)
square = Image.fromarray(np.clip(out, 0, 255).astype(np.uint8)).crop(body).resize((1024, 1024), Image.LANCZOS)

images = []
for points in (16, 32, 128, 256, 512):
    for factor in (1, 2):
        name = f'icon_{points}x{points}' + ('@2x' if factor == 2 else '') + '.png'
        square.resize((points * factor,) * 2, Image.LANCZOS).save(os.path.join(iconset, name))
        images.append({'filename': name, 'idiom': 'mac', 'scale': f'{factor}x', 'size': f'{points}x{points}'})
with open(os.path.join(iconset, 'Contents.json'), 'w') as handle:
    json.dump({'images': images, 'info': {'author': 'xcode', 'version': 1}}, handle, indent=2)
print(f'wrote {len(images)} icons to {iconset}')
