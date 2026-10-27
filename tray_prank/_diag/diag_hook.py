#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Временный диагностический скрипт: печатает все события клавиатуры,
которые видит низкоуровневый хук, и какой символ даёт каждое событие.

    python diag_hook.py 6      # слушать 6 секунд, писать в diag_hook.log
"""

import ctypes
import ctypes.wintypes as wt
import sys
import time

import tray_prank as tp

LOG = open("diag_hook.log", "w", encoding="utf-8")


def write(line):
    LOG.write(line + "\n")
    LOG.flush()


def char_for(vk, scan):
    state = (ctypes.c_ubyte * 256)()
    if not tp.user32.GetKeyboardState(state):
        return "<нет состояния>"
    buf = ctypes.create_unicode_buffer(8)
    hkl = tp.user32.GetKeyboardLayout(0)
    count = tp.user32.ToUnicodeEx(
        vk, scan, state, ctypes.cast(buf, ctypes.POINTER(ctypes.c_wchar)), 8, 0x04, hkl,
    )
    if count == 1:
        return repr(buf[0])
    return "count=%d" % count


START = time.time()


def hook(n_code, w_param, l_param):
    if n_code == tp.HC_ACTION:
        kb = ctypes.cast(l_param, ctypes.POINTER(tp.KBDLLHOOKSTRUCT)).contents
        msg = w_param & 0xFFFF
        write("%7.3f msg=0x%04X vk=0x%02X scan=0x%02X flags=0x%X extra=0x%X char=%s" % (
            time.time() - START, msg, kb.vkCode, kb.scanCode, kb.flags,
            kb.dwExtraInfo, char_for(kb.vkCode, kb.scanCode),
        ))
    return tp.user32.CallNextHookEx(None, n_code, w_param, l_param)


proc = tp.HOOKPROC(hook)
handle = tp.user32.SetWindowsHookExW(
    tp.WH_KEYBOARD_LL, proc, tp.kernel32.GetModuleHandleW(None), 0,
)
write("hook=%s  (0 — ошибка)" % handle)

seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 6.0
msg = wt.MSG()
while time.time() - START < seconds:
    if tp.user32.PeekMessageW(ctypes.byref(msg), None, 0, 0, 1):
        tp.user32.TranslateMessage(ctypes.byref(msg))
        tp.user32.DispatchMessageW(ctypes.byref(msg))
    time.sleep(0.001)

tp.user32.UnhookWindowsHookEx(handle)
write("конец")
LOG.close()
