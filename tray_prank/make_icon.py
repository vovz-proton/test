#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Рисует значок для трея (tray_icon.ico и tray_icon.png).

Внешние библиотеки не нужны: картинка считается вручную, ICO и PNG
собираются побайтово. Запуск:

    python make_icon.py
"""

import math
import os
import struct
import zlib

BG = (0xC0, 0x39, 0x2B)      # красный кружок
FG = (0xFF, 0xFF, 0xFF)      # белая буква «а»
SIZES = (16, 24, 32, 48)     # кадры внутри .ico
PNG_SIZE = 128               # размер превью
SS = 4                       # сглаживание: 4x4 подпикселя на пиксель


def _in_letter(x, y, n):
    """Попадает ли точка в букву «а» (колечко + правая палочка)."""
    t = n * 0.075                       # толщина штриха
    # колечко
    cx, cy = n * 0.46, n * 0.53
    rx, ry = n * 0.165, n * 0.195
    dx, dy = (x - cx) / rx, (y - cy) / ry
    d = math.hypot(dx, dy)
    scale = min(rx, ry)
    if abs(d - 1.0) * scale <= t * 0.5:
        return True
    # правая палочка
    sx = n * 0.60
    if sx <= x <= sx + t and n * 0.33 <= y <= n * 0.72:
        return True
    return False


def render(size):
    """Возвращает список строк пикселей [(r, g, b, a), ...] размером size x size."""
    n = size * SS
    ss2 = float(SS * SS)
    cx = cy = (n - 1) / 2.0
    radius = n / 2.0 - 0.75 * SS

    bg_cov = [[0] * size for _ in range(size)]
    fg_cov = [[0] * size for _ in range(size)]

    for j in range(n):
        y = j + 0.5
        row_bg = bg_cov[j // SS]
        row_fg = fg_cov[j // SS]
        for i in range(n):
            x = i + 0.5
            if math.hypot(x - cx, y - cy) > radius:
                continue
            row_bg[i // SS] += 1
            if _in_letter(x, y, n):
                row_fg[i // SS] += 1

    rows = []
    for j in range(size):
        row = []
        for i in range(size):
            a_bg = bg_cov[j][i] / ss2
            a_fg = fg_cov[j][i] / ss2
            if a_bg <= 0.0:
                row.append((0, 0, 0, 0))
                continue
            # буква рисуется поверх кружка
            k = a_fg / a_bg
            px = tuple(int(round(BG[c] * (1.0 - k) + FG[c] * k)) for c in range(3))
            row.append((px[0], px[1], px[2], int(round(a_bg * 255))))
        rows.append(row)
    return rows


def _ico_image(size, rows):
    """Кадр ICO: BITMAPINFOHEADER + BGRA-пиксели снизу вверх + AND-маска."""
    xor = bytearray()
    for y in range(size - 1, -1, -1):
        for x in range(size):
            r, g, b, a = rows[y][x]
            xor += bytes((b, g, r, a))

    row_bytes = ((size + 31) // 32) * 4
    and_mask = bytearray()
    for y in range(size - 1, -1, -1):
        bits = bytearray(row_bytes)
        for x in range(size):
            if rows[y][x][3] == 0:
                bits[x // 8] |= 0x80 >> (x % 8)
        and_mask += bits

    header = struct.pack(
        "<IiiHHIIiiII",
        40, size, size * 2, 1, 32, 0, len(xor) + len(and_mask), 0, 0, 0, 0,
    )
    return bytes(header) + bytes(xor) + bytes(and_mask)


def write_ico(path, frames):
    out = struct.pack("<HHH", 0, 1, len(frames))
    offset = 6 + 16 * len(frames)
    for size, data in frames:
        out += struct.pack(
            "<BBBBHHII",
            size if size < 256 else 0,
            size if size < 256 else 0,
            0, 0, 1, 32, len(data), offset,
        )
        offset += len(data)
    out += b"".join(data for _, data in frames)
    with open(path, "wb") as fh:
        fh.write(out)


def write_png(path, size, rows):
    raw = b"".join(
        b"\x00" + b"".join(bytes(px) for px in row) for row in rows
    )

    def chunk(tag, data):
        return (
            struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )
    with open(path, "wb") as fh:
        fh.write(png)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    frames = [(s, _ico_image(s, render(s))) for s in SIZES]
    ico = os.path.join(here, "tray_icon.ico")
    png = os.path.join(here, "tray_icon.png")
    write_ico(ico, frames)
    write_png(png, PNG_SIZE, render(PNG_SIZE))
    print("готово: %s (%d байт)" % (ico, os.path.getsize(ico)))
    print("готово: %s (%d байт)" % (png, os.path.getsize(png)))


if __name__ == "__main__":
    main()
