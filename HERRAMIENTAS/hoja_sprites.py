#!/usr/bin/env python3
"""
hoja_sprites.py - Design tool (NOT part of the delivered program).
Builds deliverable E5 from the project's own files:

  doc/hoja_sprites.png    every sprite enlarged, grouped by role,
                          animation frames side by side
  doc/tabla_paleta.png    the 16 colors programmed through 3C8h/3C9h
  doc/tablas_sprites.txt  the db byte table of every sprite

Colors come from the same places the game uses:
  - indices 0..15  -> default VGA palette (not reprogrammed)
  - indices 16..31 -> 'paletteTable' read straight from src/main.asm

Needs Pillow:  python -m pip install pillow
Usage (run from C:\\ASM):
  python herramientas\\hoja_sprites.py
"""
import os
import re
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.exit("Pillow is missing. Install it with:  python -m pip install pillow")

ROOT = os.getcwd()
SPRITES = os.path.join(ROOT, 'sprites')
SRC = os.path.join(ROOT, 'src')
DOC = os.path.join(ROOT, 'doc')

# Default VGA colors 0..15 (8-bit RGB)
VGA = {
    0: (0, 0, 0),        1: (0, 0, 170),      2: (0, 170, 0),
    3: (0, 170, 170),    4: (170, 0, 0),      5: (170, 0, 170),
    6: (170, 85, 0),     7: (170, 170, 170),  8: (85, 85, 85),
    9: (85, 85, 255),    10: (85, 255, 85),   11: (85, 255, 255),
    12: (255, 85, 85),   13: (255, 85, 255),  14: (255, 255, 85),
    15: (255, 255, 255),
}

# Sheet layout: (section title, [(file, caption), ...])
GROUPS = [
    ("FICHAS: 8 POCIONES", [
        ("frasco1", "1 redondo"), ("frasco2", "2 alto"),
        ("frasco3", "3 matraz"), ("frasco4", "4 corazon"),
        ("frasco5", "5 cuadrado"), ("frasco6", "6 calavera"),
        ("frasco7", "7 estrella"), ("frasco8", "8 reloj"),
    ]),
    ("RETROALIMENTACION", [
        ("chispa", "chispa = toro"), ("burbuja", "burbuja = vaca"),
    ]),
    ("ANIMACION: MARCO DE SELECCION (2 cuadros)", [
        ("marco1", "cuadro 1"), ("marco2", "cuadro 2"),
    ]),
    ("ANIMACION: MASCOTA CALDERO (2 cuadros)", [
        ("caldero1", "cuadro 1"), ("caldero2", "cuadro 2"),
    ]),
]

SCALE = 8          # each pixel becomes an 8x8 block
CELL_W = 176       # width of one sprite cell on the sheet
COLS = 4


def dac_to_rgb(v):
    """6-bit DAC value (0..63) -> 8-bit channel (0..255)."""
    return min(255, v * 4 + v // 16)


def read_palette():
    """Colors 16.. from paletteTable in src/main.asm, plus their names."""
    path = os.path.join(SRC, 'main.asm')
    pal, names = {}, {}
    inside = False
    with open(path, encoding='ascii', errors='replace') as f:
        for line in f:
            if line.startswith('paletteTable'):
                inside = True
            if not inside:
                continue
            m = re.search(r'db\s+(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*;\s*(\d+)\s*(.*)', line)
            if not m:
                break                   # first line that is not a row ends it
            r, g, b, idx, name = m.groups()
            pal[int(idx)] = (int(r), int(g), int(b))
            names[int(idx)] = name.strip()
    if not pal:
        sys.exit("paletteTable not found in src/main.asm")
    return pal, names


def read_sprite(name):
    """Same text format as sprite2db.py -> list of rows of color indices."""
    cmap = {'.': 0}
    rows = []
    path = os.path.join(SPRITES, name + '.txt')
    with open(path, encoding='utf-8-sig') as f:
        for raw in f:
            line = raw.rstrip('\r\n').rstrip()
            if not line or line.startswith('#'):
                continue
            if line.startswith('map '):
                _, ch, idx = line.split()
                cmap[ch] = int(idx)
                continue
            rows.append([cmap[c] for c in line])
    return rows


def main():
    pal6, names = read_palette()
    colors = dict(VGA)
    colors.update({k: tuple(dac_to_rgb(c) for c in v) for k, v in pal6.items()})
    bg = colors.get(16, (0, 0, 0))
    text = colors.get(22, (230, 230, 230))
    title = colors.get(21, (255, 200, 60))
    os.makedirs(DOC, exist_ok=True)

    # ---- Sprite sheet ----
    sprites = {n: read_sprite(n) for _, items in GROUPS for n, _ in items}
    row_h = 18 * SCALE + 40
    height = 40
    for _, items in GROUPS:
        height += 30 + ((len(items) + COLS - 1) // COLS) * row_h
    sheet = Image.new('RGB', (COLS * CELL_W + 20, height), bg)
    d = ImageDraw.Draw(sheet)
    d.text((10, 12), "MASTERMIND ALQUIMIA - HOJA DE SPRITES  (cada pixel = %dx%d)"
           % (SCALE, SCALE), fill=title)

    y = 40
    for section, items in GROUPS:
        d.text((10, y + 8), section, fill=title)
        y += 30
        for i, (name, caption) in enumerate(items):
            rows = sprites[name]
            w, h = len(rows[0]), len(rows)
            cx = 10 + (i % COLS) * CELL_W
            cy = y + (i // COLS) * row_h
            ox = cx + (CELL_W - w * SCALE) // 2
            for yy, row in enumerate(rows):
                for xx, v in enumerate(row):
                    if v:   # 0 = transparent: background shows through
                        d.rectangle([ox + xx * SCALE, cy + yy * SCALE,
                                     ox + (xx + 1) * SCALE - 1,
                                     cy + (yy + 1) * SCALE - 1], fill=colors[v])
            d.text((cx + 4, cy + 18 * SCALE + 8),
                   "%s.txt  %dx%d  %s" % (name, w, h, caption), fill=text)
        y += ((len(items) + COLS - 1) // COLS) * row_h
    sheet.save(os.path.join(DOC, 'hoja_sprites.png'))

    # ---- Palette table ----
    idx = sorted(pal6)
    pt = Image.new('RGB', (620, 40 + 28 * len(idx)), (255, 255, 255))
    d = ImageDraw.Draw(pt)
    d.text((10, 12), "Indice   R  G  B (0..63, puerto 3C9h)   RGB 8 bits      Uso",
           fill=(0, 0, 0))
    for n, k in enumerate(idx):
        yy = 36 + n * 28
        d.rectangle([10, yy, 40, yy + 22], fill=colors[k], outline=(0, 0, 0))
        r, g, b = pal6[k]
        d.text((50, yy + 6), "%3d   %2d %2d %2d                    #%02X%02X%02X     %s"
               % (k, r, g, b, *colors[k], names[k]), fill=(0, 0, 0))
    pt.save(os.path.join(DOC, 'tabla_paleta.png'))

    # ---- Byte tables (same output as sprite2db.py) ----
    with open(os.path.join(DOC, 'tablas_sprites.txt'), 'w', encoding='ascii',
              newline='\r\n') as f:
        f.write("Tablas de bytes de los sprites (1 byte por pixel, 0 = transparente)\n")
        for _, items in GROUPS:
            for name, caption in items:
                rows = sprites[name]
                f.write("\n; %s (%s): %dx%d px = %d bytes\n"
                        % (name, caption, len(rows[0]), len(rows), len(rows[0]) * len(rows)))
                for i, r in enumerate(rows):
                    prefix = name + " db " if i == 0 else " " * (len(name) + 1) + "db "
                    f.write(prefix + ",".join("%2d" % v for v in r) + "\n")

    print("OK: doc\\hoja_sprites.png, doc\\tabla_paleta.png, doc\\tablas_sprites.txt")


if __name__ == '__main__':
    main()
