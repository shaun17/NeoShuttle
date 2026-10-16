#!/usr/bin/env python3
# Usage: python3 Scripts/make-menu-bar-icon.py [source.png] [ShuttleMenuBar.imageset]
# Needs Pillow. The source is a dark shape on a transparent (or white) background.
"""Builds the menu-bar template image: black glyph on transparent, 18 pt at 1x and 2x.

macOS tints template images itself (black or white, highlighted), so only the
shape's alpha matters. The glyph is centred with a small margin, like system icons.
"""
from PIL import Image, ImageOps
import json, os, sys

src = sys.argv[1] if len(sys.argv) > 1 else 'Branding/menu-bar-icon-source.png'
imageset = sys.argv[2] if len(sys.argv) > 2 else 'Sources/NeoShuttle/Assets.xcassets/ShuttleMenuBar.imageset'

image = Image.open(src).convert('RGBA')
alpha = image.split()[3]
if alpha.getextrema()[0] == 255:            # opaque source: derive the shape from darkness
    alpha = ImageOps.invert(image.convert('L'))
glyph = alpha.crop(alpha.getbbox())

for scale, name in ((1, 'ShuttleTemplate.png'), (2, 'ShuttleTemplate@2x.png')):
    canvas, content = 18 * scale, 15 * scale   # 15 pt glyph inside the 18 pt square
    factor = content / max(glyph.size)
    mask = glyph.resize((round(glyph.width * factor), round(glyph.height * factor)), Image.LANCZOS)
    out = Image.new('RGBA', (canvas, canvas), (0, 0, 0, 0))
    black = Image.new('RGBA', mask.size, (0, 0, 0, 255))
    out.paste(black, ((canvas - mask.width) // 2, (canvas - mask.height) // 2), mask)
    out.save(os.path.join(imageset, name))

with open(os.path.join(imageset, 'Contents.json'), 'w') as handle:
    json.dump({
        'images': [
            {'filename': 'ShuttleTemplate.png', 'idiom': 'mac', 'scale': '1x'},
            {'filename': 'ShuttleTemplate@2x.png', 'idiom': 'mac', 'scale': '2x'},
        ],
        'info': {'author': 'xcode', 'version': 1},
        'properties': {'template-rendering-intent': 'template'},
    }, handle, indent=2)
print(f'wrote menu-bar template to {imageset}')
