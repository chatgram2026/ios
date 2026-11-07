"""Builds Telegram-iOS/Chitgram.icon (Icon Composer format) from the owner's flat 1024 logo.

The logo is a white glyph on one blue. The icon keeps that blue as the fill and the glyph as its only layer, with
the glyph's alpha recovered from how far each pixel moved from the blue towards white (so the anti-aliased edges
stay smooth). Needs Pillow:

    python3 submodules/ChitgramCore/Tools/make_app_icon.py D:/ChitgramIOS/logo.png \
        Telegram/Telegram-iOS/Chitgram.icon preview.png
"""
import json
import os
import sys
from collections import Counter

from PIL import Image

source, icon_dir, preview = sys.argv[1], sys.argv[2], sys.argv[3]

logo = Image.open(source).convert('RGB')
assert logo.size == (1024, 1024), logo.size
pixels = logo.load()

# The background is the most common colour along the border.
border = Counter()
for i in range(1024):
    for x, y in ((i, 0), (i, 1023), (0, i), (1023, i), (i, 8), (8, i)):
        border[pixels[x, y]] += 1
background = border.most_common(1)[0][0]
print('background', background, '#%02X%02X%02X' % background)

br, bg, bb = background
glyph = Image.new('RGBA', (1024, 1024))
out = glyph.load()
for y in range(1024):
    for x in range(1024):
        r, g, b = pixels[x, y]
        # Red and green move furthest between this blue and white; average them for the coverage.
        coverage = ((r - br) / (255.0 - br) + (g - bg) / (255.0 - bg)) / 2.0
        alpha = max(0, min(255, int(round(coverage * 255.0))))
        out[x, y] = (255, 255, 255, alpha)

assets = os.path.join(icon_dir, 'Assets')
os.makedirs(assets, exist_ok=True)
glyph.save(os.path.join(assets, 'Glyph.png'), optimize=True)


def color(rgb):
    return 'srgb:%.5f,%.5f,%.5f,1.00000' % tuple(c / 255.0 for c in rgb)


fill = {'linear-gradient': [color(background), color(background)]}
document = {
    'fill': fill,
    'groups': [
        {
            'blend-mode': 'normal',
            'layers': [
                {
                    'blend-mode': 'normal',
                    'glass': False,
                    'image-name': 'Glyph.png',
                    'name': 'Glyph',
                }
            ],
            'lighting': 'combined',
            'shadow': {
                'kind': 'layer-color',
                'opacity': 0.5,
            },
            'specular': False,
            'translucency': {
                'enabled': False,
                'value': 1,
            },
        }
    ],
    'supported-platforms': {
        'circles': ['watchOS'],
        'squares': 'shared',
    },
}
with open(os.path.join(icon_dir, 'icon.json'), 'w', encoding='utf-8', newline='\n') as f:
    json.dump(document, f, indent=2)
    f.write('\n')

# A flat check of the result: the glyph composited back over the fill should match the logo.
composite = Image.new('RGBA', (1024, 1024), background + (255,))
composite.alpha_composite(glyph)
diff = 0
cp = composite.convert('RGB').load()
for y in range(0, 1024, 4):
    for x in range(0, 1024, 4):
        diff = max(diff, max(abs(a - b) for a, b in zip(cp[x, y], pixels[x, y])))
print('largest difference from the logo:', diff)
composite.convert('RGB').resize((256, 256), Image.LANCZOS).save(preview)
