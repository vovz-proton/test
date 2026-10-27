import sys
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools/oscilloscope'))
from scope_viewer import ScopeViewer, auto_voltage_scale
assert auto_voltage_scale(3.3, 1.0) == 1.0
assert auto_voltage_scale(8.0, 1.0) == 5.0
assert auto_voltage_scale(0.1, 2.0) == 0.05
assert auto_voltage_scale(float('nan'), 1.0) == 1.0
v = ScopeViewer.__new__(ScopeViewer)
v.auto_scale_var = SimpleNamespace(get=lambda: True)
v.auto_window_started = 0.0
v.auto_peaks = {1: None, 2: None}
v.scope_scales = {1: 1.0, 2: 2.0}
v.pending_channel_scales = {}
waves = {1: SimpleNamespace(values=[-0.1, 8.0]), 2: SimpleNamespace(values=[-0.02, 0.02])}
v._auto_scale(waves, {}, {}, 0.2)
assert not v.pending_channel_scales
waves[1].values = [0.0]
with patch('scope_viewer.time.monotonic', return_value=0.6):
    v._auto_scale(waves, {}, {}, 0.6)
assert v.pending_channel_scales == {1: 5.0, 2: 0.01}, v.pending_channel_scales
assert v.auto_peaks == {1: None, 2: None}
v.auto_scale_var = SimpleNamespace(get=lambda: False)
v.pending_channel_scales.clear()
v._auto_scale(waves, {}, {}, 2.0)
assert not v.pending_channel_scales
print('PASS: half-second peak window, independent ranges, margin/hysteresis, invalid data, manual override')