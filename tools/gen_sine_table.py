#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Генератор таблицы синуса (Q15) для Core/Src/dac_sine.c

Использование:
    python tools/gen_sine_table.py            # 32 точки (по умолчанию)
    python tools/gen_sine_table.py 200        # другое число точек на период

Печатает готовый массив C, который нужно вставить в dac_sine.c
(и синхронно поменять DAC_SINE_SAMPLES в dac_sine.h).
"""

import math
import sys

N = int(sys.argv[1]) if len(sys.argv) > 1 else 32

vals = [int(round(32767.0 * math.sin(2.0 * math.pi * i / N))) for i in range(N)]

print("/* %d точек на период, sin() * 32767 (Q15) */" % N)
print("static const int16_t sine[DAC_SINE_SAMPLES] =")
print("{")
for i in range(0, N, 10):
    chunk = ", ".join("%7d" % v for v in vals[i:i + 10])
    tail = "," if i + 10 < N else ""
    print("  " + chunk + tail)
print("};")
