#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Трей-программа-шутка для Windows.

Что делает
----------
* висит значком в системном трее (правый нижний угол, у часов);
* пока включена — ловит нажатие клавиши «а» (в русской раскладке это «а»,
  в английской — та же физическая клавиша «a») и вместо неё «печатает»
  последовательность «хуйна»;
* при выходе показывает окно «Ну блин, не понравилось чтоли?».

Внешних библиотек не требует: только стандартная библиотека Python и WinAPI
через ctypes.

Запуск
------
    pythonw.exe tray_prank.py          без окна консоли
    start_hidden.vbs                   то же самое, но двойным щелчком
    python.exe tray_prank.py --debug   с отладочным выводом в консоль

Выход
-----
    правый клик по значку в трее -> «Выход»
    pythonw.exe tray_prank.py --quit   (попросить закрыться уже запущенную копию)

Ключи
-----
    --text ТЕКСТ     что печатать вместо «а» (по умолчанию «хуйна»)
    --no-question    выйти молча, без прощального окна
    --quit           закрыть уже запущенную копию
    --quit-after N   закрыться самому через N секунд (удобно для проверки)
    --debug          писать отладку в консоль
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.wintypes as wt
import os
import sys
import threading
import time

# ------------------------------------------------------------------ настройки

APP_NAME = "Хуйна-трей"                       # подпись у значка в трее
APP_CLASS = "TrayPrankWndClass_v1"            # имя класса скрытого окна
FAREWELL = "Ну блин, не понравилось чтоли?"   # окно при выходе
DEFAULT_TEXT = "хуйна"                        # что печатается вместо «а»
TRIGGER_CHARS = ("а", "a")                    # какие символы считаются «кнопкой а»
SWALLOW_TRIGGER = True                        # True: сама «а» не печатается
START_DELAY = 0.04                            # пауза перед началом «печати», с
CHAR_DELAY = 0.018                            # пауза между символами, с
TRIGGER_COOLDOWN = 0.15                       # защита от повторов, с
TRAY_ID = 1
ICON_FILE = "tray_icon.ico"

# -------------------------------------------------------------------- WinAPI

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
shell32 = ctypes.WinDLL("shell32", use_last_error=True)

LRESULT = ctypes.c_ssize_t
ULONG_PTR = ctypes.c_size_t
UINT_PTR = ctypes.c_size_t

WNDPROC = ctypes.WINFUNCTYPE(LRESULT, wt.HWND, wt.UINT, wt.WPARAM, wt.LPARAM)
HOOKPROC = ctypes.WINFUNCTYPE(LRESULT, ctypes.c_int, wt.WPARAM, wt.LPARAM)

WM_NULL = 0x0000
WM_DESTROY = 0x0002
WM_CLOSE = 0x0010
WM_COMMAND = 0x0111
WM_KEYDOWN = 0x0100
WM_KEYUP = 0x0101
WM_SYSKEYDOWN = 0x0104
WM_SYSKEYUP = 0x0105
WM_LBUTTONDBLCLK = 0x0203
WM_RBUTTONUP = 0x0205
WM_CONTEXTMENU = 0x007B
WM_APP = 0x8000

WM_TRAY = WM_APP + 1        # сообщение от значка в трее
WM_DO_TYPE = WM_APP + 2     # «напечатай текст» (ставится из хука)
WM_QUIT_CMD = WM_APP + 3    # «выходи» (можно прислать из другой копии)

WS_POPUP = 0x80000000
WS_EX_TOOLWINDOW = 0x00000080

WH_KEYBOARD_LL = 13
HC_ACTION = 0

VK_SHIFT = 0x10
VK_CONTROL = 0x11
VK_MENU = 0x12                     # Alt
VK_LWIN = 0x5B
VK_RWIN = 0x5C

INPUT_KEYBOARD = 1
KEYEVENTF_KEYUP = 0x0002
KEYEVENTF_UNICODE = 0x0004

NIM_ADD = 0x00000000
NIM_MODIFY = 0x00000001
NIM_DELETE = 0x00000002
NIF_MESSAGE = 0x00000001
NIF_ICON = 0x00000002
NIF_TIP = 0x00000004
NIF_INFO = 0x00000010
NIIF_INFO = 0x00000001

MF_STRING = 0x00000000
MF_SEPARATOR = 0x00000800
MF_CHECKED = 0x00000008
TPM_RIGHTBUTTON = 0x0002
TPM_RETURNCMD = 0x0100

IDM_TOGGLE = 1001
IDM_QUIT = 1002

MB_OK = 0x00000000
MB_ICONINFORMATION = 0x00000040
MB_SETFOREGROUND = 0x00010000
MB_TOPMOST = 0x00040000

IMAGE_ICON = 1
LR_LOADFROMFILE = 0x0010
SM_CXSMICON = 49
SM_CYSMICON = 50
IDI_APPLICATION = 32512


class GUID(ctypes.Structure):
    _fields_ = [
        ("Data1", wt.DWORD), ("Data2", wt.WORD), ("Data3", wt.WORD),
        ("Data4", ctypes.c_ubyte * 8),
    ]


class WNDCLASSEXW(ctypes.Structure):
    _fields_ = [
        ("cbSize", wt.UINT),
        ("style", wt.UINT),
        ("lpfnWndProc", WNDPROC),
        ("cbClsExtra", ctypes.c_int),
        ("cbWndExtra", ctypes.c_int),
        ("hInstance", wt.HINSTANCE),
        ("hIcon", wt.HICON),
        ("hCursor", wt.HCURSOR),
        ("hbrBackground", wt.HBRUSH),
        ("lpszMenuName", wt.LPCWSTR),
        ("lpszClassName", wt.LPCWSTR),
        ("hIconSm", wt.HICON),
    ]


class NOTIFYICONDATAW(ctypes.Structure):
    _fields_ = [
        ("cbSize", wt.DWORD),
        ("hWnd", wt.HWND),
        ("uID", wt.UINT),
        ("uFlags", wt.UINT),
        ("uCallbackMessage", wt.UINT),
        ("hIcon", wt.HICON),
        ("szTip", wt.WCHAR * 128),
        ("dwState", wt.DWORD),
        ("dwStateMask", wt.DWORD),
        ("szInfo", wt.WCHAR * 256),
        ("uTimeout", wt.UINT),          # он же uVersion
        ("szInfoTitle", wt.WCHAR * 64),
        ("dwInfoFlags", wt.DWORD),
        ("guidItem", GUID),
        ("hBalloonIcon", wt.HICON),
    ]


class KBDLLHOOKSTRUCT(ctypes.Structure):
    _fields_ = [
        ("vkCode", wt.DWORD),
        ("scanCode", wt.DWORD),
        ("flags", wt.DWORD),
        ("time", wt.DWORD),
        ("dwExtraInfo", ULONG_PTR),
    ]


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [
        ("dx", wt.LONG), ("dy", wt.LONG), ("mouseData", wt.DWORD),
        ("dwFlags", wt.DWORD), ("time", wt.DWORD), ("dwExtraInfo", ULONG_PTR),
    ]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ("wVk", wt.WORD), ("wScan", wt.WORD), ("dwFlags", wt.DWORD),
        ("time", wt.DWORD), ("dwExtraInfo", ULONG_PTR),
    ]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [("uMsg", wt.DWORD), ("wParamL", wt.WORD), ("wParamH", wt.WORD)]


class _INPUTUNION(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _anonymous_ = ("u",)
    _fields_ = [("type", wt.DWORD), ("u", _INPUTUNION)]


# прототипы — чтобы ctypes не путал 32- и 64-битные аргументы
user32.RegisterClassExW.argtypes = [ctypes.POINTER(WNDCLASSEXW)]
user32.RegisterClassExW.restype = wt.WORD
user32.CreateWindowExW.argtypes = [
    wt.DWORD, wt.LPCWSTR, wt.LPCWSTR, wt.DWORD,
    ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
    wt.HWND, wt.HMENU, wt.HINSTANCE, ctypes.c_void_p,
]
user32.CreateWindowExW.restype = wt.HWND
user32.DefWindowProcW.argtypes = [wt.HWND, wt.UINT, wt.WPARAM, wt.LPARAM]
user32.DefWindowProcW.restype = LRESULT
user32.DestroyWindow.argtypes = [wt.HWND]
user32.GetMessageW.argtypes = [ctypes.POINTER(wt.MSG), wt.HWND, wt.UINT, wt.UINT]
user32.GetMessageW.restype = ctypes.c_int
user32.TranslateMessage.argtypes = [ctypes.POINTER(wt.MSG)]
user32.DispatchMessageW.argtypes = [ctypes.POINTER(wt.MSG)]
user32.DispatchMessageW.restype = LRESULT
user32.PostMessageW.argtypes = [wt.HWND, wt.UINT, wt.WPARAM, wt.LPARAM]
user32.PostQuitMessage.argtypes = [ctypes.c_int]
user32.SetWindowsHookExW.argtypes = [ctypes.c_int, HOOKPROC, wt.HINSTANCE, wt.DWORD]
user32.SetWindowsHookExW.restype = wt.HANDLE
user32.UnhookWindowsHookEx.argtypes = [wt.HANDLE]
user32.CallNextHookEx.argtypes = [wt.HANDLE, ctypes.c_int, wt.WPARAM, wt.LPARAM]
user32.CallNextHookEx.restype = LRESULT
user32.GetKeyboardState.argtypes = [ctypes.POINTER(ctypes.c_ubyte)]
user32.GetKeyboardLayout.argtypes = [wt.DWORD]
user32.GetKeyboardLayout.restype = wt.HKL
user32.ToUnicodeEx.argtypes = [
    wt.UINT, wt.UINT, ctypes.POINTER(ctypes.c_ubyte),
    ctypes.POINTER(ctypes.c_wchar), ctypes.c_int, wt.UINT, wt.HKL,
]
user32.ToUnicodeEx.restype = ctypes.c_int
user32.GetAsyncKeyState.argtypes = [ctypes.c_int]
user32.GetAsyncKeyState.restype = ctypes.c_short
user32.SendInput.argtypes = [wt.UINT, ctypes.POINTER(INPUT), ctypes.c_int]
user32.SendInput.restype = wt.UINT
user32.LoadImageW.argtypes = [wt.HINSTANCE, wt.LPCWSTR, wt.UINT, ctypes.c_int, ctypes.c_int, wt.UINT]
user32.LoadImageW.restype = wt.HANDLE
user32.LoadIconW.argtypes = [wt.HINSTANCE, ctypes.c_void_p]
user32.LoadIconW.restype = wt.HANDLE
user32.DestroyIcon.argtypes = [wt.HICON]
user32.GetSystemMetrics.argtypes = [ctypes.c_int]
user32.GetSystemMetrics.restype = ctypes.c_int
user32.CreatePopupMenu.restype = wt.HMENU
user32.AppendMenuW.argtypes = [wt.HMENU, wt.UINT, UINT_PTR, wt.LPCWSTR]
user32.TrackPopupMenu.argtypes = [
    wt.HMENU, wt.UINT, ctypes.c_int, ctypes.c_int, ctypes.c_int, wt.HWND, ctypes.c_void_p,
]
user32.TrackPopupMenu.restype = ctypes.c_int
user32.DestroyMenu.argtypes = [wt.HMENU]
user32.SetForegroundWindow.argtypes = [wt.HWND]
user32.GetCursorPos.argtypes = [ctypes.POINTER(wt.POINT)]
user32.MessageBoxW.argtypes = [wt.HWND, wt.LPCWSTR, wt.LPCWSTR, wt.UINT]
user32.MessageBoxW.restype = ctypes.c_int
user32.FindWindowW.argtypes = [wt.LPCWSTR, wt.LPCWSTR]
user32.FindWindowW.restype = wt.HWND
shell32.Shell_NotifyIconW.argtypes = [wt.DWORD, ctypes.POINTER(NOTIFYICONDATAW)]
shell32.Shell_NotifyIconW.restype = wt.BOOL
kernel32.GetModuleHandleW.argtypes = [wt.LPCWSTR]
kernel32.GetModuleHandleW.restype = wt.HMODULE


def set_wstr(struct, field_name, text):
    """Копирует строку в поле-буфер фиксированной длины внутри структуры.

    Поля вида WCHAR * N при чтении отдаются как обычная строка, поэтому адрес
    и размер берём у описания поля, а не у значения.
    """
    field = getattr(type(struct), field_name)
    chars = field.size // ctypes.sizeof(ctypes.c_wchar)
    src = ctypes.create_unicode_buffer(text, chars)
    ctypes.memmove(ctypes.addressof(struct) + field.offset, src, ctypes.sizeof(src))


def log(message):
    if DEBUG:
        sys.stderr.write("[tray_prank] %s\n" % message)
        sys.stderr.flush()


DEBUG = False


class TrayPrankApp(object):
    """Значок в трее + перехват клавиши «а» + прощальное окно."""

    def __init__(self, text=DEFAULT_TEXT, ask_on_exit=True, debug=False):
        global DEBUG
        DEBUG = debug
        self.text = text
        self.ask_on_exit = ask_on_exit

        self.hwnd = None
        self.hook = None
        self.icon = None
        self.icon_owned = False
        self.enabled = True
        self.typing = False
        self._quitting = False
        self._last_trigger = 0.0
        self._swallow_up = set()
        self._type_lock = threading.Lock()

        self._wndproc = WNDPROC(self._on_message)
        self._hookproc = HOOKPROC(self._on_key)
        self._class_name = APP_CLASS

    # ------------------------------------------------------------- окно и трей

    def _load_icon(self):
        here = os.path.dirname(os.path.abspath(__file__))
        path = os.path.join(here, ICON_FILE)
        cx = user32.GetSystemMetrics(SM_CXSMICON) or 16
        cy = user32.GetSystemMetrics(SM_CYSMICON) or 16
        if os.path.isfile(path):
            handle = user32.LoadImageW(None, path, IMAGE_ICON, cx, cy, LR_LOADFROMFILE)
            if handle:
                self.icon_owned = True
                return handle
            log("не удалось загрузить %s, беру системный значок" % path)
        return user32.LoadIconW(None, IDI_APPLICATION)

    def _create_window(self):
        self.icon = self._load_icon()
        wc = WNDCLASSEXW()
        wc.cbSize = ctypes.sizeof(WNDCLASSEXW)
        wc.lpfnWndProc = self._wndproc
        wc.hInstance = kernel32.GetModuleHandleW(None)
        wc.hIcon = self.icon
        wc.hIconSm = self.icon
        wc.lpszClassName = self._class_name
        if not user32.RegisterClassExW(ctypes.byref(wc)):
            err = ctypes.get_last_error()
            if err != 1410:                     # ERROR_CLASS_ALREADY_EXISTS
                raise ctypes.WinError(err)
        self.hwnd = user32.CreateWindowExW(
            WS_EX_TOOLWINDOW, self._class_name, APP_NAME, WS_POPUP,
            0, 0, 0, 0, None, None, wc.hInstance, None,
        )
        if not self.hwnd:
            raise ctypes.WinError(ctypes.get_last_error())
        log("окно создано: hwnd=%s" % self.hwnd)

    def _tray_data(self):
        nid = NOTIFYICONDATAW()
        nid.cbSize = ctypes.sizeof(NOTIFYICONDATAW)
        nid.hWnd = self.hwnd
        nid.uID = TRAY_ID
        nid.hIcon = self.icon
        return nid

    def _tip(self):
        if self.enabled:
            return "%s: нажми «а»" % APP_NAME
        return "%s: выключено" % APP_NAME

    def _add_tray_icon(self):
        nid = self._tray_data()
        nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP
        nid.uCallbackMessage = WM_TRAY
        set_wstr(nid, "szTip", self._tip())
        if not shell32.Shell_NotifyIconW(NIM_ADD, ctypes.byref(nid)):
            raise ctypes.WinError(ctypes.get_last_error())
        nid.uFlags = NIF_INFO
        nid.dwInfoFlags = NIIF_INFO
        nid.uTimeout = 5000
        set_wstr(nid, "szInfoTitle", APP_NAME)
        set_wstr(nid, "szInfo", "Работаю. Нажми «а» — и увидишь. Выход — в меню значка.")
        shell32.Shell_NotifyIconW(NIM_MODIFY, ctypes.byref(nid))
        log("значок добавлен в трей")

    def _refresh_tray_icon(self):
        nid = self._tray_data()
        nid.uFlags = NIF_TIP
        set_wstr(nid, "szTip", self._tip())
        shell32.Shell_NotifyIconW(NIM_MODIFY, ctypes.byref(nid))

    def _remove_tray_icon(self):
        if not self.hwnd:
            return
        nid = self._tray_data()
        shell32.Shell_NotifyIconW(NIM_DELETE, ctypes.byref(nid))

    # ---------------------------------------------------------------- хук клавы

    def _install_hook(self):
        self.hook = user32.SetWindowsHookExW(
            WH_KEYBOARD_LL, self._hookproc, kernel32.GetModuleHandleW(None), 0,
        )
        if not self.hook:
            raise ctypes.WinError(ctypes.get_last_error())
        log("клавиатурный хук установлен: hhook=%s" % self.hook)

    def _uninstall_hook(self):
        if self.hook:
            user32.UnhookWindowsHookEx(self.hook)
            self.hook = None

    def _char_for(self, vk, scan):
        """Какой символ даст это нажатие в текущей раскладке."""
        state = (ctypes.c_ubyte * 256)()
        if not user32.GetKeyboardState(state):
            return None
        if user32.GetAsyncKeyState(VK_SHIFT) & 0x8000:
            state[VK_SHIFT] |= 0x80             # в хуке состояние Shift бывает stale
        buf = ctypes.create_unicode_buffer(8)
        hkl = user32.GetKeyboardLayout(0)
        count = user32.ToUnicodeEx(
            vk, scan, state,
            ctypes.cast(buf, ctypes.POINTER(ctypes.c_wchar)), 8, 0x04, hkl,
        )
        if count == 1:
            return buf[0]
        return None

    def _modifiers_down(self):
        for vk in (VK_CONTROL, VK_MENU, VK_LWIN, VK_RWIN):
            if user32.GetAsyncKeyState(vk) & 0x8000:
                return True
        return False

    def _is_trigger(self, kb):
        if self._modifiers_down():
            return False                        # Ctrl+A, Alt+… не трогаем
        char = self._char_for(kb.vkCode, kb.scanCode)
        return bool(char) and char.lower() in TRIGGER_CHARS

    def _on_key(self, n_code, w_param, l_param):
        """Низкоуровневый хук: вызывается на каждое нажатие любой клавиши."""
        try:
            if n_code != HC_ACTION:
                return user32.CallNextHookEx(None, n_code, w_param, l_param)
            msg = w_param & 0xFFFF
            kb = ctypes.cast(l_param, ctypes.POINTER(KBDLLHOOKSTRUCT)).contents

            if msg in (WM_KEYUP, WM_SYSKEYUP):
                if kb.vkCode in self._swallow_up:
                    self._swallow_up.discard(kb.vkCode)
                    return 1                    # гасим отпускание «а»
                return user32.CallNextHookEx(None, n_code, w_param, l_param)

            if msg not in (WM_KEYDOWN, WM_SYSKEYDOWN):
                return user32.CallNextHookEx(None, n_code, w_param, l_param)

            if kb.vkCode == 0:
                return user32.CallNextHookEx(None, n_code, w_param, l_param)

            if not (self.enabled and self.hwnd) or self.typing:
                return user32.CallNextHookEx(None, n_code, w_param, l_param)

            if not self._is_trigger(kb):
                return user32.CallNextHookEx(None, n_code, w_param, l_param)

            now = time.monotonic()
            if now - self._last_trigger < TRIGGER_COOLDOWN:
                return 1 if SWALLOW_TRIGGER else user32.CallNextHookEx(None, n_code, w_param, l_param)
            self._last_trigger = now
            self._swallow_up.add(kb.vkCode)
            user32.PostMessageW(self.hwnd, WM_DO_TYPE, 0, 0)
            log("нажата «а» (vk=%d) — печатаю %r" % (kb.vkCode, self.text))
            return 1 if SWALLOW_TRIGGER else user32.CallNextHookEx(None, n_code, w_param, l_param)
        except Exception as exc:                # хук обязан всегда отвечать
            log("ошибка в хуке: %r" % (exc,))
            return user32.CallNextHookEx(None, n_code, w_param, l_param)

    # ----------------------------------------------------------------- печать

    def _send_char(self, char):
        inputs = (INPUT * 2)()
        for index, flags in enumerate((KEYEVENTF_UNICODE, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP)):
            inputs[index].type = INPUT_KEYBOARD
            inputs[index].ki.wVk = 0
            inputs[index].ki.wScan = ord(char)
            inputs[index].ki.dwFlags = flags
        sent = user32.SendInput(2, inputs, ctypes.sizeof(INPUT))
        if sent != 2:
            log("SendInput вернул %d" % sent)

    def _type_worker(self, text):
        with self._type_lock:
            self.typing = True
            try:
                time.sleep(START_DELAY)
                for char in text:
                    self._send_char(char)
                    time.sleep(CHAR_DELAY)
                time.sleep(0.05)
            except Exception as exc:
                log("ошибка печати: %r" % (exc,))
            finally:
                self.typing = False

    def _spawn_typing(self):
        threading.Thread(target=self._type_worker, args=(self.text,), daemon=True).start()

    # ------------------------------------------------------------------- меню

    def _toggle(self):
        self.enabled = not self.enabled
        self._refresh_tray_icon()
        log("перехват %s" % ("включён" if self.enabled else "выключен"))

    def _show_menu(self):
        menu = user32.CreatePopupMenu()
        flags = MF_STRING | (MF_CHECKED if self.enabled else 0)
        user32.AppendMenuW(menu, flags, IDM_TOGGLE, "Ловить клавишу «а»")
        user32.AppendMenuW(menu, MF_SEPARATOR, 0, None)
        user32.AppendMenuW(menu, MF_STRING, IDM_QUIT, "Выход")
        point = wt.POINT()
        user32.GetCursorPos(ctypes.byref(point))
        user32.SetForegroundWindow(self.hwnd)
        command = user32.TrackPopupMenu(
            menu, TPM_RIGHTBUTTON | TPM_RETURNCMD,
            point.x, point.y, 0, self.hwnd, None,
        )
        user32.PostMessageW(self.hwnd, WM_NULL, 0, 0)
        user32.DestroyMenu(menu)
        if command == IDM_TOGGLE:
            self._toggle()
        elif command == IDM_QUIT:
            self._quit()

    # ------------------------------------------------------------------ выход

    def _quit(self):
        if self._quitting:
            return
        self._quitting = True
        log("выход")
        self._remove_tray_icon()
        self._uninstall_hook()
        if self.ask_on_exit:
            user32.MessageBoxW(
                None, FAREWELL, APP_NAME,
                MB_OK | MB_ICONINFORMATION | MB_SETFOREGROUND | MB_TOPMOST,
            )
        if self.hwnd:
            user32.DestroyWindow(self.hwnd)

    def _on_message(self, hwnd, msg, w_param, l_param):
        try:
            if msg == WM_TRAY:
                event = l_param & 0xFFFF
                if event in (WM_RBUTTONUP, WM_CONTEXTMENU):
                    self._show_menu()
                elif event == WM_LBUTTONDBLCLK:
                    self._toggle()
                return 0
            if msg == WM_DO_TYPE:
                self._spawn_typing()
                return 0
            if msg in (WM_QUIT_CMD, WM_CLOSE):
                self._quit()
                return 0
            if msg == WM_DESTROY:
                user32.PostQuitMessage(0)
                return 0
        except Exception as exc:
            log("ошибка в обработчике окна: %r" % (exc,))
        return user32.DefWindowProcW(hwnd, msg, w_param, l_param)

    # ------------------------------------------------------------------- цикл

    def run(self, quit_after=None):
        self._create_window()
        self._add_tray_icon()
        self._install_hook()
        if quit_after:
            timer = threading.Timer(quit_after, self._post_quit)
            timer.daemon = True
            timer.start()
        log("готово, жду нажатий")
        msg = wt.MSG()
        while True:
            result = user32.GetMessageW(ctypes.byref(msg), None, 0, 0)
            if result in (0, -1):
                break
            user32.TranslateMessage(ctypes.byref(msg))
            user32.DispatchMessageW(ctypes.byref(msg))
        self._remove_tray_icon()
        self._uninstall_hook()
        if self.hwnd:
            user32.DestroyWindow(self.hwnd)
            self.hwnd = None
        if self.icon and self.icon_owned:
            user32.DestroyIcon(self.icon)
        log("завершено")

    def _post_quit(self):
        if self.hwnd:
            user32.PostMessageW(self.hwnd, WM_QUIT_CMD, 0, 0)


def ask_running_copy_to_quit():
    """Ищем уже запущенную копию и просим её закрыться."""
    other = user32.FindWindowW(APP_CLASS, None)
    if not other:
        return False
    user32.PostMessageW(other, WM_QUIT_CMD, 0, 0)
    return True


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Трей-программа: вместо «а» печатает «%s»." % DEFAULT_TEXT,
    )
    parser.add_argument("--text", default=DEFAULT_TEXT, help="что печатать")
    parser.add_argument("--no-question", action="store_true",
                        help="выйти без прощального окна")
    parser.add_argument("--quit", action="store_true",
                        help="закрыть уже запущенную копию")
    parser.add_argument("--quit-after", type=float, default=None, metavar="СЕК",
                        help="закрыться самому через N секунд (для проверки)")
    parser.add_argument("--debug", action="store_true", help="отладка в консоль")
    args = parser.parse_args(argv)

    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    if args.quit:
        if ask_running_copy_to_quit():
            print("запущенной копии отправлен сигнал на выход")
        else:
            print("запущенная копия не найдена")
        return 0

    if user32.FindWindowW(APP_CLASS, None):
        print("программа уже запущена (значок в трее)")
        return 1

    app = TrayPrankApp(
        text=args.text,
        ask_on_exit=not args.no_question,
        debug=args.debug,
    )
    app.run(quit_after=args.quit_after)
    return 0


if __name__ == "__main__":
    sys.exit(main())
