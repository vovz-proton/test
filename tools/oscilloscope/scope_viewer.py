#!/usr/bin/env python3
"""Live Windows viewer/controller for UNI-T UTD2102CL+ over NI-VISA USBTMC."""

from __future__ import annotations

import ctypes
import ctypes.util
import math
import queue
import struct
import threading
import time
import tkinter as tk
from collections import deque
from dataclasses import dataclass
from tkinter import messagebox, ttk


RESOURCE = "USB0::0x5656::0x0832::1474742912::INSTR"
VISA_DLL = r"C:\Windows\System32\visa64.dll"
VISA_ATTR_TMO_VALUE = 0x3FFF001A

VOLT_PER_DIV = [1e-3, 2e-3, 5e-3, 10e-3, 20e-3, 50e-3,
                0.1, 0.2, 0.5, 1.0, 2.0, 5.0, 10.0, 20.0]
TIME_PER_DIV = [2e-9, 5e-9, 10e-9, 20e-9, 50e-9, 100e-9, 200e-9, 500e-9,
                1e-6, 2e-6, 5e-6, 10e-6, 20e-6, 50e-6, 100e-6, 200e-6,
                500e-6, 1e-3, 2e-3, 5e-3, 10e-3, 20e-3, 50e-3, 100e-3,
                200e-3, 500e-3, 1.0, 2.0, 5.0, 10.0, 20.0, 50.0]
GHOST_LIFETIME = 0.5
GHOST_SAMPLE_INTERVAL = 0.04


def si(value: float, unit: str) -> str:
    if not math.isfinite(value):
        return "—"
    a = abs(value)
    for factor, prefix in ((1e-9, "н"), (1e-6, "мк"), (1e-3, "м"),
                           (1.0, ""), (1e3, "к"), (1e6, "М")):
        if a < factor * 1000 or factor == 1e6:
            return f"{value / factor:.4g} {prefix}{unit}"
    return f"{value:.4g} {unit}"


def volts_label(value: float) -> str:
    if value < 1:
        return f"{value * 1000:g} мВ/дел"
    return f"{value:g} В/дел"


def time_label(value: float) -> str:
    if value < 1e-6:
        return f"{value * 1e9:g} нс/дел"
    if value < 1e-3:
        return f"{value * 1e6:g} мкс/дел"
    if value < 1:
        return f"{value * 1e3:g} мс/дел"
    return f"{value:g} с/дел"


def parse_scpi_number(text: str) -> float:
    cleaned = text.strip().replace(",", ".")
    if not cleaned or cleaned == "*":
        raise ValueError(f"Прибор вернул пустое значение: {text!r}")
    return float(cleaned)


@dataclass
class Waveform:
    channel: int
    values: list[float]
    seconds: list[float]
    volts_per_div: float
    time_per_div: float
    start_time: float
    end_time: float
    point_count: int


class VisaError(RuntimeError):
    pass


class VisaScope:
    """Small direct NI-VISA binding; no PyVISA or other Python packages needed."""

    def __init__(self) -> None:
        if not hasattr(ctypes, "WinDLL"):
            raise VisaError("Эта программа работает в Windows.")
        try:
            self.dll = ctypes.WinDLL(VISA_DLL)
        except OSError as exc:
            raise VisaError(f"Не найдена NI-VISA: {VISA_DLL}\n{exc}") from exc

        u32 = ctypes.c_uint32
        i32 = ctypes.c_int32
        self.dll.viOpenDefaultRM.argtypes = [ctypes.POINTER(u32)]
        self.dll.viOpenDefaultRM.restype = i32
        self.dll.viOpen.argtypes = [u32, ctypes.c_char_p, u32, u32, ctypes.POINTER(u32)]
        self.dll.viOpen.restype = i32
        self.dll.viSetAttribute.argtypes = [u32, u32, ctypes.c_size_t]
        self.dll.viSetAttribute.restype = i32
        self.dll.viWrite.argtypes = [u32, ctypes.c_void_p, u32, ctypes.POINTER(u32)]
        self.dll.viWrite.restype = i32
        self.dll.viRead.argtypes = [u32, ctypes.c_void_p, u32, ctypes.POINTER(u32)]
        self.dll.viRead.restype = i32
        self.dll.viClose.argtypes = [u32]
        self.dll.viClose.restype = i32

        self.rm = u32(0)
        self.session = u32(0)
        self.original: dict[str, str] = {}
        self._check(self.dll.viOpenDefaultRM(ctypes.byref(self.rm)), "открыть NI-VISA")
        status = self.dll.viOpen(self.rm, RESOURCE.encode("ascii"), 0, 0,
                                 ctypes.byref(self.session))
        self._check(status, f"открыть осциллограф {RESOURCE}")
        self._check(self.dll.viSetAttribute(self.session, VISA_ATTR_TMO_VALUE, 5000),
                    "установить таймаут NI-VISA")
        try:
            self.original = {
                "source": self.query(":WAVeform:SOURce?"),
                "format": self.query(":WAVeform:FORMat?"),
                "mode": self.query(":WAVeform:MODE?"),
            }
            self.write(":WAVeform:FORMat WORD")
            self.write(":WAVeform:MODE NORMal")
            self.identity = self.query("*IDN?")
        except Exception:
            self.close(restore=False)
            raise

    @staticmethod
    def _check(status: int, action: str) -> None:
        # NI-VISA non-negative statuses include successful warnings; negative is failure.
        if status < 0:
            raise VisaError(f"NI-VISA: {action}, статус {status}")

    def write(self, command: str) -> None:
        data = (command + "\n").encode("ascii")
        buffer = ctypes.create_string_buffer(data)
        written = ctypes.c_uint32(0)
        status = self.dll.viWrite(self.session, buffer, len(data), ctypes.byref(written))
        self._check(status, f"отправить {command!r}")
        if written.value != len(data):
            raise VisaError(f"Короткая запись команды {command!r}: {written.value}/{len(data)}")

    def read(self, limit: int = 1 << 20) -> bytes:
        buffer = ctypes.create_string_buffer(limit)
        count = ctypes.c_uint32(0)
        status = self.dll.viRead(self.session, buffer, limit, ctypes.byref(count))
        self._check(status, "прочитать ответ")
        return buffer.raw[:count.value]

    def query_bytes(self, command: str) -> bytes:
        self.write(command)
        return self.read()

    def query(self, command: str) -> str:
        return self.query_bytes(command).decode("ascii", errors="replace").strip("\x00\r\n ")

    def get_number(self, command: str) -> float:
        return parse_scpi_number(self.query(command))

    def get_waveform(self, channel: int, restore_source: bool = True) -> Waveform:
        source_before = self.original.get("source", "CHANnel1")
        try:
            self.write(f":WAVeform:SOURce CHANnel{channel}")
            preamble = self.query(":WAVeform:PREamble?").split(",")
            if len(preamble) < 10:
                raise VisaError(f"Неожиданная преамбула CH{channel}: {preamble}")
            points = int(float(preamble[2]))
            x_inc, x_origin, x_ref = map(float, preamble[4:7])
            y_inc, y_origin, y_ref = map(float, preamble[7:10])
            if points <= 0 or x_inc <= 0 or y_inc == 0:
                raise VisaError(f"Неверные параметры преамбулы CH{channel}: {preamble}")

            response = self.query_bytes(":WAVeform:DATA?")
            if len(response) < 3 or response[0:1] != b"#":
                raise VisaError(f"CH{channel}: нет заголовка блока IEEE 488.2")
            digit_count = response[1] - ord("0")
            if not 1 <= digit_count <= 9 or len(response) < 2 + digit_count:
                raise VisaError(f"CH{channel}: испорчен заголовок блока")
            header_end = 2 + digit_count
            payload_size = int(response[2:header_end].decode("ascii"))
            payload = response[header_end:header_end + payload_size]
            if len(payload) != payload_size:
                raise VisaError(f"CH{channel}: неполный блок, {len(payload)}/{payload_size} байт")
            if payload_size % 2:
                raise VisaError(f"CH{channel}: WORD-блок имеет нечётный размер {payload_size}")
            codes = struct.unpack("<" + "H" * (payload_size // 2), payload)
            if not codes:
                raise VisaError(f"CH{channel}: осциллограф вернул пустую форму")

            # UTD2102CL+ reports 800 screen points but WORD mode returns 1600
            # codes on this device. Map all returned codes over the time span
            # defined by the preamble; this keeps the displayed time/div correct.
            x_span = x_inc * points
            sample_step = x_span / max(1, len(codes))
            start = x_origin - x_ref * sample_step
            seconds = [start + i * sample_step for i in range(len(codes))]
            volts = [(code - y_ref) * y_inc + y_origin for code in codes]
            return Waveform(channel, volts, seconds, 0.0, 0.0, start,
                            start + x_span, points)
        finally:
            # WAVeform:SOURce selects only the readout source; restore it after each capture.
            if restore_source and source_before:
                self.write(f":WAVeform:SOURce {source_before}")

    def set_channel_scale(self, channel: int, value: float) -> float:
        # This firmware applies SCALe to the selected front-panel channel,
        # even when the command explicitly names another channel.
        self.write(f":CHANnel{channel}:SELect")
        self.write(f":CHANnel{channel}:SCALe {value:.12g}V")
        for _ in range(5):
            actual = self.get_number(f":CHANnel{channel}:SCALe?")
            if math.isclose(actual, value, rel_tol=0.02):
                return actual
            time.sleep(0.05)
        raise VisaError(f"CH{channel}: прибор не установил {volts_label(value)}; "
                        f"прочитано {volts_label(actual)}")

    def set_timebase(self, value: float) -> float:
        self.write(f":TIMebase:SCALe {value:.12g}")
        return self.get_number(":TIMebase:SCALe?")

    def read_scales(self) -> tuple[dict[int, float], float]:
        channels = {ch: self.get_number(f":CHANnel{ch}:SCALe?") for ch in (1, 2)}
        return channels, self.get_number(":TIMebase:SCALe?")

    def close(self, restore: bool = True) -> None:
        if self.session.value:
            if restore and self.original:
                for key, command in (("source", ":WAVeform:SOURce {}"),
                                     ("format", ":WAVeform:FORMat {}"),
                                     ("mode", ":WAVeform:MODE {}")):
                    value = self.original.get(key)
                    if value:
                        try:
                            self.write(command.format(value))
                        except Exception:
                            pass
            self.dll.viClose(self.session)
            self.session.value = 0
        if self.rm.value:
            self.dll.viClose(self.rm)
            self.rm.value = 0


def nearest_index(options: list[float], value: float) -> int:
    return min(range(len(options)), key=lambda i: abs(math.log(options[i] / value)))


def auto_voltage_scale(peak: float, current: float) -> float:
    """Fit absolute voltage into +/-3 divisions, retaining room for peaks."""
    if not math.isfinite(peak) or peak < 0:
        return current
    if 1.2 * current <= peak <= 3.5 * current:
        return current
    needed = max(peak / 3.0, VOLT_PER_DIV[0])
    return next((value for value in VOLT_PER_DIV if value >= needed), VOLT_PER_DIV[-1])


class ScopeViewer:
    BG = "#101820"
    PANEL = "#17232d"
    GRID = "#344b58"
    TEXT = "#e7edf2"
    MUTED = "#aab7c0"
    COLORS = {1: "#4bd6e8", 2: "#ffd447"}

    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.root.title("UNI-T UTD2102CL+ — осциллограф на ПК")
        self.root.geometry("1280x900")
        self.root.minsize(900, 680)
        self.root.configure(bg=self.BG)
        self.scope: VisaScope | None = None
        self.scope_scales: dict[int, float] = {}
        self.display_scales: dict[int, float] = {}
        self.scope_timebase = 0.0
        self.scope_means: dict[int, float | None] = {1: None, 2: None}
        self.scope_vpps: dict[int, float | None] = {1: None, 2: None}
        self.scope_mean_updated = 0.0
        self.data: dict[int, Waveform] = {}
        self.mean_voltages: dict[int, float | None] = {1: None, 2: None}
        self.vpp_voltages: dict[int, float | None] = {1: None, 2: None}
        self.trace_history: dict[int, list[tuple[float, Waveform]]] = {1: [], 2: []}
        self.last_capture_time: dict[int, float] = {1: 0.0, 2: 0.0}
        self.last_ghost_time: dict[int, float] = {1: 0.0, 2: 0.0}
        self.fade_timer_scheduled = False
        self.grid_cache: dict[int, tuple] = {}
        self.jobs: queue.Queue[tuple] = queue.Queue()
        self.results: queue.Queue[tuple] = queue.Queue()
        self.worker_thread = threading.Thread(target=self._worker, daemon=True)
        self.worker_thread.start()
        self.connected = False
        self.polling = True
        self.busy = False
        self.closed = False
        self.closing = False
        self.channel_controls: dict[int, ttk.Combobox] = {}
        self.canvases: dict[int, tk.Canvas] = {}
        self.channel_scale_vars: dict[int, tk.StringVar] = {}
        self.pending_time_scale: float | None = None
        self.pending_channel_scales: dict[int, float] = {}
        self.auto_window_started = time.monotonic()
        self.auto_peaks: dict[int, float | None] = {1: None, 2: None}
        self._build_ui()
        self.root.protocol("WM_DELETE_WINDOW", self.close)
        self.root.after(5, self._drain_results)
        self.root.after(300, self.connect)

    def _build_ui(self) -> None:
        style = ttk.Style()
        style.theme_use("clam")
        style.configure("TFrame", background=self.BG)
        style.configure("Panel.TFrame", background=self.PANEL)
        style.configure("TLabel", background=self.BG, foreground=self.TEXT, font=("Segoe UI", 10))
        style.configure("Panel.TLabel", background=self.PANEL, foreground=self.TEXT, font=("Segoe UI", 10))
        style.configure("Title.TLabel", background=self.BG, foreground=self.TEXT,
                        font=("Segoe UI Semibold", 16))
        style.configure("Status.TLabel", background=self.PANEL, foreground=self.MUTED,
                        font=("Segoe UI", 9))
        style.configure("TButton", padding=(10, 6), font=("Segoe UI", 10))
        style.configure("TCombobox", padding=5)

        header = ttk.Frame(self.root, padding=(14, 12, 14, 8))
        header.pack(fill="x")
        ttk.Label(header, text="UNI-T UTD2102CL+", style="Title.TLabel").pack(side="left")
        self.status_var = tk.StringVar(value="Подключение к USBTMC...")
        ttk.Label(header, textvariable=self.status_var).pack(side="left", padx=(20, 0))
        self.connect_button = ttk.Button(header, text="Подключить", command=self.connect)
        self.connect_button.pack(side="right", padx=(8, 0))
        self.read_button = ttk.Button(header, text="Считать сейчас", command=self.capture_now)
        self.read_button.pack(side="right", padx=(8, 0))
        self.poll_button = ttk.Button(header, text="Остановить обновление", command=self.toggle_polling)
        self.poll_button.pack(side="right")

        controls = ttk.Frame(self.root, style="Panel.TFrame", padding=(14, 10))
        controls.pack(fill="x", padx=14, pady=(0, 8))
        ttk.Label(controls, text="Развёртка по времени — общая для CH1 и CH2:",
                  style="Panel.TLabel").pack(side="left")
        self.time_var = tk.StringVar()
        self.time_combo = ttk.Combobox(controls, textvariable=self.time_var, state="readonly",
                                       width=16, values=[time_label(x) for x in TIME_PER_DIV])
        self.time_combo.pack(side="left", padx=(8, 5))
        self.time_combo.bind("<<ComboboxSelected>>", self._on_time_selected)
        self.auto_scale_var = tk.BooleanVar(value=True)
        ttk.Checkbutton(controls, text="Авто В/дел · 0,5 с",
                        variable=self.auto_scale_var, command=self._reset_auto_window).pack(side="left", padx=8)
        ttk.Label(controls, text="Развёртка времени отправляется на прибор.",
                  style="Status.TLabel").pack(side="left", padx=8)
        ttk.Label(controls, text="Колесо меняет масштаб выбранного графика · Ctrl+колесо: время",
                  style="Status.TLabel").pack(side="right", padx=8)

        charts = ttk.Frame(self.root, padding=(14, 0, 14, 0))
        charts.pack(fill="both", expand=True)
        for ch in (1, 2):
            panel = ttk.Frame(charts, style="Panel.TFrame", padding=8)
            panel.pack(fill="both", expand=True, pady=(0, 8))
            bar = ttk.Frame(panel, style="Panel.TFrame")
            bar.pack(fill="x", pady=(0, 6))
            ttk.Label(bar, text=f"CH{ch}", style="Panel.TLabel",
                      foreground=self.COLORS[ch], font=("Segoe UI Semibold", 11)).pack(side="left")
            ttk.Label(bar, text="Масштаб на приборе:", style="Panel.TLabel").pack(side="left", padx=(18, 5))
            scale_var = tk.StringVar()
            combo = ttk.Combobox(bar, textvariable=scale_var, state="readonly", width=15,
                                 values=[volts_label(x) for x in VOLT_PER_DIV])
            combo.pack(side="left")
            combo.bind("<<ComboboxSelected>>", lambda _e, channel=ch: self._on_channel_selected(channel))
            ttk.Label(bar, text="V/div", style="Status.TLabel").pack(side="left", padx=6)
            self.channel_scale_vars[ch] = scale_var
            self.channel_controls[ch] = combo
            canvas = tk.Canvas(panel, background=self.BG, highlightthickness=0, height=255)
            canvas.pack(fill="both", expand=True)
            canvas.bind("<Configure>", lambda _e, channel=ch: self._draw_channel(channel))
            self.canvases[ch] = canvas

        footer = ttk.Frame(self.root, style="Panel.TFrame", padding=(12, 7))
        footer.pack(fill="x", padx=14, pady=(0, 12))
        self.footer_var = tk.StringVar(value=f"VISA: {RESOURCE}")
        ttk.Label(footer, textvariable=self.footer_var, style="Status.TLabel").pack(side="left")
        self.update_var = tk.StringVar(value="Ожидание данных")
        ttk.Label(footer, textvariable=self.update_var, style="Status.TLabel").pack(side="right")
        # Windows/Tk can send wheel events to the focused widget instead of the
        # plot under the pointer. Route before widget/class bindings (Combobox
        # otherwise consumes the wheel and can change the wrong channel).
        wheel_tag = f"ScopeWheel{id(self)}"
        self.root.bind_class(wheel_tag, "<MouseWheel>", self._route_wheel)

        def install_wheel_route(widget):
            widget.bindtags((wheel_tag,) + widget.bindtags())
            for child in widget.winfo_children():
                install_wheel_route(child)

        install_wheel_route(self.root)

    def connect(self) -> None:
        if self.busy:
            return
        if self.connected:
            self.capture_now()
            return
        self.busy = True
        self.status_var.set("Открываю NI-VISA...")
        self.jobs.put(("connect",))

    def capture_now(self) -> None:
        if self.busy:
            return
        if not self.connected:
            self.connect()
            return
        self.busy = True
        self.update_var.set("Считываю CH1 и CH2…")
        self.jobs.put(("capture",))

    def toggle_polling(self) -> None:
        self.polling = not self.polling
        self.poll_button.configure(text="Остановить обновление" if self.polling else "Продолжить обновление")
        if self.polling and self.connected:
            self.capture_now()

    def _on_channel_selected(self, channel: int) -> None:
        if not self.connected:
            return
        index = self.channel_controls[channel].current()
        if index < 0:
            return
        value = VOLT_PER_DIV[index]
        self.auto_scale_var.set(False)
        self._reset_auto_window()
        self.display_scales[channel] = value
        self._draw_channel(channel)
        self.pending_channel_scales[channel] = value
        self._dispatch_pending_controls()

    def _reset_auto_window(self) -> None:
        self.auto_window_started = time.monotonic()
        self.auto_peaks = {1: None, 2: None}

    def _auto_scale(self, waves, means, vpps, now: float) -> None:
        if not self.auto_scale_var.get():
            self._reset_auto_window()
            return
        for ch, wave in waves.items():
            values = [abs(v) for v in wave.values if math.isfinite(v)]
            mean, vpp = means.get(ch), vpps.get(ch)
            if mean is not None and vpp is not None and math.isfinite(mean) and math.isfinite(vpp) and vpp >= 0:
                # Mean need not lie midway between extrema (e.g. narrow pulses).
                values.append(abs(mean) + vpp)
            if values:
                peak = max(values)
                previous = self.auto_peaks[ch]
                self.auto_peaks[ch] = peak if previous is None else max(previous, peak)
        if now - self.auto_window_started < 0.5:
            return
        for ch, peak in self.auto_peaks.items():
            if peak is None or ch in self.pending_channel_scales:
                continue
            current = self.scope_scales.get(ch)
            if current is None or current <= 0:
                continue
            target = auto_voltage_scale(peak, current)
            if not math.isclose(target, current, rel_tol=0.02):
                self.pending_channel_scales[ch] = target
        self._reset_auto_window()

    def _on_time_selected(self, _event=None) -> None:
        if not self.connected:
            return
        index = self.time_combo.current()
        if index < 0:
            return
        self.pending_time_scale = TIME_PER_DIV[index]
        self._dispatch_pending_controls()

    def _dispatch_pending_controls(self) -> bool:
        """Send the latest manual range change once the VISA worker is free."""
        if not self.connected or self.busy:
            return False
        if self.pending_channel_scales:
            channel = next(iter(self.pending_channel_scales))
            value = self.pending_channel_scales.pop(channel)
            self.busy = True
            self.status_var.set(f"CH{channel}: устанавливаю {volts_label(value)} на приборе…")
            self.jobs.put(("set_channel", channel, value))
            return True
        if self.pending_time_scale is not None:
            value = self.pending_time_scale
            self.pending_time_scale = None
            self.busy = True
            self.status_var.set(f"Устанавливаю развёртку {time_label(value)}…")
            self.jobs.put(("set_time", value))
            return True
        return False

    @staticmethod
    def _wheel_steps(event) -> int:
        delta = getattr(event, "delta", 0)
        if not delta:
            return 0
        return max(1, round(abs(delta) / 120))

    def _step_scale(self, event, channel: int | None = None) -> str:
        """Wheel zooms the selected range; Ctrl+wheel changes time on a plot."""
        if not self.connected:
            return "break"
        steps = self._wheel_steps(event)
        if not steps:
            return "break"
        zoom_in = event.delta > 0
        use_timebase = channel is None or bool(event.state & 0x0004)
        if use_timebase:
            if not self.connected:
                return "break"
            combo, options = self.time_combo, TIME_PER_DIV
            pending_index = nearest_index(options, self.pending_time_scale) if self.pending_time_scale else -1
            current = pending_index if pending_index >= 0 else combo.current()
            if current < 0:
                actual = self.data[1].time_per_div if 1 in self.data else options[0]
                current = nearest_index(options, actual)
            new_index = max(0, min(len(options) - 1, current + (-steps if zoom_in else steps)))
            if new_index != current:
                combo.current(new_index)
                self._on_time_selected()
        else:
            combo, options = self.channel_controls[channel], VOLT_PER_DIV
            current = combo.current()
            if current < 0:
                actual = self.data[channel].volts_per_div if channel in self.data else options[0]
                current = nearest_index(options, actual)
            new_index = max(0, min(len(options) - 1, current + (-steps if zoom_in else steps)))
            if new_index != current:
                combo.current(new_index)
                self._on_channel_selected(channel)
        return "break"

    def _route_wheel(self, event):
        widget = self.root.winfo_containing(event.x_root, event.y_root)
        while widget is not None:
            if widget == self.time_combo:
                return self._wheel_time(event)
            for channel in (1, 2):
                if widget in (self.canvases[channel], self.channel_controls[channel]):
                    return self._wheel_on_plot(event, channel)
            widget = getattr(widget, "master", None)
        # Do not let a focused combobox change when the pointer is elsewhere.
        return "break"

    def _wheel_channel(self, event, channel: int) -> str:
        return self._step_scale(event, channel)

    def _wheel_on_plot(self, event, channel: int) -> str:
        return self._step_scale(event, channel)

    def _wheel_time(self, event) -> str:
        return self._step_scale(event)

    def _worker(self) -> None:
        while True:
            try:
                job = self.jobs.get(timeout=0.2)
            except queue.Empty:
                continue
            operation = job[0]
            try:
                if operation == "connect":
                    self.scope = VisaScope()
                    self.scope_scales, self.scope_timebase = self.scope.read_scales()
                    result = ("connected", self.scope.identity,
                              self.scope_scales.copy(), self.scope_timebase)
                elif operation == "capture":
                    if not self.scope:
                        raise VisaError("Сначала подключитесь к осциллографу.")
                    started = time.perf_counter()
                    try:
                        waves = {ch: self.scope.get_waveform(ch, restore_source=False) for ch in (1, 2)}
                    finally:
                        source = self.scope.original.get("source", "CHANnel1")
                        self.scope.write(f":WAVeform:SOURce {source}")
                    scales, tdiv = self.scope_scales.copy(), self.scope_timebase
                    measure_time = time.monotonic()
                    if measure_time - self.scope_mean_updated >= 0.5:
                        means: dict[int, float | None] = {}
                        vpps: dict[int, float | None] = {}
                        for ch in (1, 2):
                            try:
                                means[ch] = self.scope.get_number(f":MEASure:VAVerage? CHANnel{ch}")
                            except (ValueError, VisaError):
                                means[ch] = None
                            try:
                                vpps[ch] = self.scope.get_number(f":MEASure:VPP? CHANnel{ch}")
                            except (ValueError, VisaError):
                                vpps[ch] = None
                        self.scope_means = means
                        self.scope_vpps = vpps
                        self.scope_mean_updated = measure_time
                    means = self.scope_means.copy()
                    vpps = self.scope_vpps.copy()
                    for ch, wave in waves.items():
                        wave.volts_per_div = scales[ch]
                        wave.time_per_div = tdiv
                    elapsed_ms = (time.perf_counter() - started) * 1000
                    result = ("capture", waves, scales, tdiv, elapsed_ms, means, vpps)
                elif operation == "set_channel":
                    if not self.scope:
                        raise VisaError("Осциллограф не подключён.")
                    channel, value = job[1], job[2]
                    actual = self.scope.set_channel_scale(channel, value)
                    self.scope_scales[channel] = actual
                    result = ("channel_set", channel, actual)
                elif operation == "set_time":
                    if not self.scope:
                        raise VisaError("Осциллограф не подключён.")
                    actual = self.scope.set_timebase(job[1])
                    self.scope_timebase = actual
                    result = ("time_set", actual)
                elif operation == "disconnect":
                    if self.scope:
                        self.scope.close(restore=True)
                        self.scope = None
                    result = ("disconnected",)
                elif operation == "shutdown":
                    try:
                        if self.scope:
                            self.scope.close(restore=True)
                            self.scope = None
                    finally:
                        self.results.put(("closed",))
                    return
                else:
                    result = ("error", f"Неизвестная операция: {operation}")
            except Exception as exc:
                result = ("error", str(exc))
                if operation == "connect" and self.scope:
                    self.scope.close(restore=False)
                    self.scope = None
            self.results.put(result)

    def _drain_results(self) -> None:
        while True:
            try:
                result = self.results.get_nowait()
            except queue.Empty:
                break
            self.busy = False
            kind = result[0]
            if kind == "connected":
                _, identity, scales, tdiv = result
                self.connected = True
                self.display_scales = scales.copy()
                self.status_var.set("Подключён")
                self.footer_var.set(f"{identity}  ·  VISA {RESOURCE}")
                self._set_controls(scales, tdiv)
                if self.polling:
                    self.root.after(50, self.capture_now)
            elif kind == "capture":
                _, waves, scales, tdiv, elapsed_ms, means, vpps = result
                self.mean_voltages.update(means)
                self.vpp_voltages.update(vpps)
                captured_at = time.monotonic()
                self._auto_scale(waves, means, vpps, captured_at)
                for ch, wave in waves.items():
                    previous = self.data.get(ch)
                    last_ghost = self.last_ghost_time[ch]
                    if previous is not None and captured_at - last_ghost >= GHOST_SAMPLE_INTERVAL:
                        self.trace_history[ch].append((self.last_capture_time[ch], previous))
                        self.last_ghost_time[ch] = captured_at
                        self.trace_history[ch] = [
                            item for item in self.trace_history[ch]
                            if captured_at - item[0] < GHOST_LIFETIME
                        ][-12:]
                    self.last_capture_time[ch] = captured_at
                self.data.update(waves)
                if any(self.trace_history.values()):
                    self._schedule_fade_tick()
                self._set_controls(scales, tdiv)
                for ch in (1, 2):
                    self._draw_channel(ch)
                self.status_var.set("Подключён · данные обновляются")
                self.update_var.set(f"Обновлено {time.strftime('%H:%M:%S')}  ·  чтение {elapsed_ms:.0f} мс  ·  {len(waves[1].values)} отсчётов/канал")
                self._dispatch_pending_controls()
                if self.polling:
                    self.root.after(1, self.capture_now)
            elif kind == "channel_set":
                _, channel, actual = result
                if channel not in self.pending_channel_scales:
                    self.display_scales[channel] = actual
                self._set_controls(self.scope_scales, self.scope_timebase)
                self._draw_channel(channel)
                self.status_var.set(f"CH{channel}: на приборе {volts_label(actual)}")
                if not self._dispatch_pending_controls():
                    self.capture_now()
            elif kind == "time_set":
                _, actual = result
                self._select_option(self.time_combo, TIME_PER_DIV, actual, self.time_var, time_label)
                self.status_var.set(f"Развёртка: {time_label(actual)}")
                if not self._dispatch_pending_controls():
                    self.capture_now()
            elif kind == "disconnected":
                self.connected = False
                self.status_var.set("Отключён")
                self.update_var.set("Подключение закрыто")
            elif kind == "error":
                self.status_var.set("Нет связи / ошибка чтения")
                self.update_var.set(result[1])
                if not self.connected:
                    self.footer_var.set(f"VISA: {RESOURCE}")
                elif self.polling:
                    self.root.after(1500, self.capture_now)
            elif kind == "closed":
                self.closed = True
                self.root.destroy()
        if not self.closed:
            self.root.after(5, self._drain_results)

    def _set_controls(self, scales: dict[int, float], tdiv: float) -> None:
        for ch, value in scales.items():
            display_value = self.display_scales.setdefault(ch, value)
            self._select_option(self.channel_controls[ch], VOLT_PER_DIV, display_value,
                                self.channel_scale_vars[ch], volts_label)
        self._select_option(self.time_combo, TIME_PER_DIV, tdiv, self.time_var, time_label)

    @staticmethod
    def _select_option(combo: ttk.Combobox, options: list[float], actual: float,
                       var: tk.StringVar, formatter) -> None:
        index = nearest_index(options, actual)
        if abs(options[index] - actual) / max(actual, 1e-15) < 0.02:
            combo.current(index)
        else:
            var.set(formatter(actual))

    @staticmethod
    def _fade_color(color: str, background: str, strength: float) -> str:
        strength = max(0.0, min(1.0, strength))
        foreground = tuple(int(color[i:i + 2], 16) for i in (1, 3, 5))
        base = tuple(int(background[i:i + 2], 16) for i in (1, 3, 5))
        mixed = tuple(round(b + (f - b) * strength) for f, b in zip(foreground, base))
        return "#" + "".join(f"{value:02x}" for value in mixed)

    def _schedule_fade_tick(self) -> None:
        if not self.fade_timer_scheduled and not self.closed and not self.closing:
            self.fade_timer_scheduled = True
            self.root.after(20, self._fade_tick)

    def _fade_tick(self) -> None:
        self.fade_timer_scheduled = False
        now = time.monotonic()
        any_history = False
        for ch in (1, 2):
            kept = [(stamp, wave) for stamp, wave in self.trace_history[ch]
                    if now - stamp < GHOST_LIFETIME]
            if kept or len(kept) != len(self.trace_history[ch]):
                self._draw_channel(ch)
            self.trace_history[ch] = kept
            any_history |= bool(kept)
        if any_history:
            self._schedule_fade_tick()

    def _draw_channel(self, channel: int) -> None:
        canvas = self.canvases.get(channel)
        if not canvas:
            return
        width = max(100, canvas.winfo_width())
        height = max(120, canvas.winfo_height())
        left, right, top, bottom = 62, width - 16, 15, height - 34
        plot_width, plot_height = right - left, bottom - top
        if plot_width <= 0 or plot_height <= 0:
            return
        wave = self.data.get(channel)
        scale = self.display_scales.get(channel, wave.volts_per_div) if wave else 1.0
        tdiv = wave.time_per_div if wave else 1.0
        full_time = max(wave.end_time - wave.start_time, tdiv * 8) if wave else tdiv * 8
        # Grid, ticks and labels are static until the window or either axis changes.
        background_key = (width, height, scale, tdiv, bool(wave))
        if self.grid_cache.get(channel) != background_key:
            canvas.delete("background")
            for i in range(9):
                x = left + i * plot_width / 8
                y = top + i * plot_height / 8
                canvas.create_line(x, top, x, bottom, fill=self.GRID, width=1, tags="background")
                canvas.create_line(left, y, right, y, fill=self.GRID, width=1, tags="background")
            canvas.create_line(left, top + plot_height / 2, right, top + plot_height / 2,
                               fill="#607987", width=1, tags="background")
            if wave:
                for i in range(9):
                    division = 4 - i
                    value = division * scale
                    y = top + i * plot_height / 8
                    label = "0" if division == 0 else si(value, "В")
                    canvas.create_text(left - 8, y, text=label, fill=self.MUTED,
                                       anchor="e", font=("Segoe UI", 8), tags="background")
                    seconds = -full_time + full_time * i / 8
                    canvas.create_text(left + i * plot_width / 8, bottom + 13,
                                       text=si(seconds, "с"), fill=self.MUTED,
                                       anchor="n", font=("Segoe UI", 8), tags="background")
                scale_label = f"График {volts_label(scale)} · прибор {volts_label(wave.volts_per_div)}" \
                    if not math.isclose(scale, wave.volts_per_div, rel_tol=1e-6) else \
                    f"{volts_label(scale)}  ·  {time_label(tdiv)}"
                canvas.create_text(right - 4, top + 4,
                                   text=scale_label,
                                   fill=self.TEXT, anchor="ne", font=("Segoe UI", 9), tags="background")
                if len(wave.values) != wave.point_count:
                    canvas.create_text(left + 4, top + 4,
                                       text=f"{len(wave.values)} значений, {wave.point_count} точек преамбулы",
                                       fill="#d5bf74", anchor="nw", font=("Segoe UI", 8), tags="background")
            else:
                canvas.create_text(width / 2, height / 2, text="Ожидаю форму сигнала…",
                                   fill=self.MUTED, font=("Segoe UI", 11), tags="background")
            self.grid_cache[channel] = background_key

        canvas.delete("traces")
        if not wave:
            return

        def draw_trace(trace: Waveform, color: str, limit: int) -> None:
            count = min(len(trace.values), len(trace.seconds))
            stride = max(1, math.ceil(count / limit))
            points: list[float] = []
            for index in range(0, count, stride):
                seconds = trace.seconds[index]
                volts = trace.values[index]
                x = right + (seconds - trace.end_time) / full_time * plot_width
                y = top + plot_height / 2 - volts / scale * (plot_height / 8)
                points.extend((x, y))
            if len(points) >= 4:
                canvas.create_line(*points, fill=color, width=1.3,
                                   smooth=False, joinstyle=tk.ROUND, tags="traces")

        now = time.monotonic()
        visible_history = []
        for stamp, old_wave in self.trace_history[channel]:
            age = now - stamp
            if 0 <= age < GHOST_LIFETIME:
                visible_history.append((stamp, old_wave))
                strength = (1.0 - age / GHOST_LIFETIME) ** 1.5
                draw_trace(old_wave, self._fade_color(self.COLORS[channel], self.BG, strength), 600)
        self.trace_history[channel] = visible_history[-12:]
        draw_trace(wave, self.COLORS[channel], 1200)
        mean = self.mean_voltages.get(channel)
        mean_text = f"Среднее: {si(mean, 'В')}" if mean is not None else "Среднее: —"
        canvas.create_text(right - 4, top + 21, text=mean_text,
                           fill=self.COLORS[channel], anchor="ne",
                           font=("Segoe UI Semibold", 9), tags="traces")
        vpp = self.vpp_voltages.get(channel)
        vpp_text = f"VPP: {si(vpp, 'В')}" if vpp is not None else "VPP: —"
        canvas.create_text(right - 4, top + 37, text=vpp_text,
                           fill=self.COLORS[channel], anchor="ne",
                           font=("Segoe UI", 8), tags="traces")

    def close(self) -> None:
        if self.closed or self.closing:
            return
        self.closing = True
        self.busy = True
        self.polling = False
        # Let the worker finish its current command and restore the scope's
        # original waveform source/format/mode before the window exits.
        self.jobs.put(("shutdown",))


def main() -> None:
    root = tk.Tk()
    ScopeViewer(root)
    root.mainloop()


if __name__ == "__main__":
    main()
