# Placeholder pixel art for the Godot trial (temporary: replace with real sprites later).
import random, sys
from PIL import Image, ImageDraw
out = sys.argv[1]; random.seed(7)
T = 16
# tiles.png: 8 columns x 1 row
# 0 grass, 1 path, 2 rock, 3 rock top (snow ridge), 4 tunnel mouth, 5 tunnel floor, 6 tunnel wall, 7 flowers
tiles = Image.new('RGBA', (T * 8, T), (0, 0, 0, 0)); d = ImageDraw.Draw(tiles)
def noise(x0, base, var, n=40):
    d.rectangle([x0, 0, x0 + T - 1, T - 1], fill=base)
    for _ in range(n):
        x, y = random.randrange(T), random.randrange(T); c = tuple(max(0, min(255, b + random.randint(-var, var))) for b in base[:3]) + (255,)
        d.point((x0 + x, y), fill=c)
noise(0, (78, 140, 70, 255), 18)                      # grass
noise(T, (176, 142, 96, 255), 14)                     # path
noise(2 * T, (112, 108, 116, 255), 16)                # rock
d.line([2 * T, T - 1, 3 * T - 1, T - 1], fill=(70, 66, 74, 255))
noise(3 * T, (112, 108, 116, 255), 16)                # rock top
d.rectangle([3 * T, 0, 4 * T - 1, 4], fill=(236, 240, 246, 255))
for x in range(T): d.point((3 * T + x, 5 + (x % 3 == 0)), fill=(200, 206, 216, 255))
noise(4 * T, (112, 108, 116, 255), 16)                # tunnel mouth (dark arch)
d.ellipse([4 * T + 2, 2, 5 * T - 3, T + 10], fill=(24, 20, 26, 255))
d.rectangle([4 * T + 2, 9, 5 * T - 3, T - 1], fill=(24, 20, 26, 255))
d.line([4 * T + 2, 3, 4 * T + 2, T - 1], fill=(150, 112, 70, 255)); d.line([5 * T - 3, 3, 5 * T - 3, T - 1], fill=(150, 112, 70, 255))
d.line([4 * T + 2, 3, 5 * T - 3, 3], fill=(150, 112, 70, 255))  # wooden frame
noise(5 * T, (70, 56, 44, 255), 10)                   # tunnel floor
noise(6 * T, (52, 50, 58, 255), 10)                   # tunnel wall
for y in (4, 10): d.line([6 * T, y, 7 * T - 1, y], fill=(36, 34, 40, 255))
noise(7 * T, (78, 140, 70, 255), 18)                  # grass with flowers
for (x, y, c) in ((3, 4, (240, 220, 90)), (10, 9, (230, 120, 140)), (6, 12, (240, 240, 250))): d.rectangle([7 * T + x, y, 7 * T + x + 1, y + 1], fill=c + (255,))
tiles.save(f'{out}/tiles.png')
# player.png: 4 frames x 4 rows (down, left, right, up), 16x24 each. Cobalt hair, as in the web game.
W, H = 16, 24; sheet = Image.new('RGBA', (W * 4, H * 4), (0, 0, 0, 0)); p = ImageDraw.Draw(sheet)
HAIR, SKIN, SHIRT, PANTS, BOOT, EYE = (40, 72, 170), (240, 200, 160), (200, 120, 60), (70, 60, 90), (60, 40, 30), (20, 20, 30)
for row, facing in enumerate(('down', 'left', 'right', 'up')):
    for f in range(4):
        ox, oy = f * W, row * H; step = (0, 1, 0, -1)[f]
        p.rectangle([ox + 4, oy + 2, ox + 11, oy + 9], fill=SKIN)                        # head
        p.rectangle([ox + 4, oy + 1, ox + 11, oy + 4], fill=HAIR)                        # hair
        if facing == 'up': p.rectangle([ox + 4, oy + 1, ox + 11, oy + 9], fill=HAIR)
        if facing == 'down': p.point([(ox + 6, oy + 6), (ox + 9, oy + 6)], fill=EYE)
        if facing == 'left': p.point([(ox + 5, oy + 6)], fill=EYE); p.rectangle([ox + 10, oy + 2, ox + 11, oy + 8], fill=HAIR)
        if facing == 'right': p.point([(ox + 10, oy + 6)], fill=EYE); p.rectangle([ox + 4, oy + 2, ox + 5, oy + 8], fill=HAIR)
        p.rectangle([ox + 4, oy + 10, ox + 11, oy + 16], fill=SHIRT)                     # body
        arm = 1 if step else 0
        p.rectangle([ox + 3, oy + 11 + arm * step, ox + 3, oy + 15 + arm * step], fill=SKIN)
        p.rectangle([ox + 12, oy + 11 - arm * step, ox + 12, oy + 15 - arm * step], fill=SKIN)
        p.rectangle([ox + 5, oy + 17, ox + 10, oy + 19], fill=PANTS)
        l, r = (2 if step > 0 else 0), (2 if step < 0 else 0)                            # legs alternate
        p.rectangle([ox + 5, oy + 20, ox + 7, oy + 22 - l], fill=PANTS); p.rectangle([ox + 5, oy + 23 - l, ox + 7, oy + 23 - l], fill=BOOT)
        p.rectangle([ox + 8, oy + 20, ox + 10, oy + 22 - r], fill=PANTS); p.rectangle([ox + 8, oy + 23 - r, ox + 10, oy + 23 - r], fill=BOOT)
sheet.save(f'{out}/player.png')
# workshop.png: 48x48
ws = Image.new('RGBA', (48, 48), (0, 0, 0, 0)); w = ImageDraw.Draw(ws)
w.polygon([(2, 20), (24, 4), (46, 20)], fill=(170, 60, 50, 255)); w.line([(2, 20), (24, 4), (46, 20)], fill=(110, 36, 30, 255))
w.rectangle([6, 20, 42, 46], fill=(150, 110, 70, 255)); w.rectangle([6, 20, 42, 46], outline=(96, 66, 40, 255))
w.rectangle([20, 32, 28, 46], fill=(90, 60, 36, 255))                                   # door
for x in (10, 32): w.rectangle([x, 26, x + 6, 32], fill=(250, 220, 120, 255)); w.rectangle([x, 26, x + 6, 32], outline=(96, 66, 40, 255))
w.rectangle([30, 6, 34, 14], fill=(90, 88, 96, 255))                                    # chimney
ws.save(f'{out}/workshop.png')
print('art written')
