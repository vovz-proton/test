import sys
from pathlib import Path
from unittest.mock import patch
import tkinter as tk
sys.path.insert(0, str(Path('tools/oscilloscope').resolve()))
from scope_viewer import ScopeViewer, VOLT_PER_DIV

root = tk.Tk()
try:
    with patch('threading.Thread.start'), patch.object(ScopeViewer, 'connect'):
        viewer = ScopeViewer(root)
        root.update()
        root.focus_force()
        viewer.channel_controls[2].focus_set()
        root.update()
        viewer.connected = True
        viewer.busy = True
        viewer._set_controls({1: 1.0, 2: 2.0}, 50e-6)
        def wheel(target, delta, state=0):
            x = target.winfo_rootx() + target.winfo_width() // 2
            y = target.winfo_rooty() + target.winfo_height() // 2
            # Deliver to the wrong focused widget, with pointer over target.
            with patch.object(root, 'winfo_containing', return_value=target):
                viewer.channel_controls[2].event_generate('<MouseWheel>',
                    delta=delta, state=state, rootx=x, rooty=y)
                root.update()
        wheel(viewer.canvases[1], 120)
        assert viewer.display_scales == {1: 0.5, 2: 2.0}, viewer.display_scales
        wheel(viewer.canvases[2], -120)
        assert viewer.display_scales == {1: 0.5, 2: 5.0}
        viewer._set_controls({1: 1.0, 2: 2.0}, 50e-6)
        assert viewer.channel_controls[1].current() == VOLT_PER_DIV.index(0.5)
        wheel(viewer.canvases[1], 120, 4)
        assert viewer.pending_time_scale == 20e-6, viewer.pending_time_scale
        assert viewer.pending_channel_scales == {1: 0.5, 2: 5.0}
        assert viewer.display_scales == {1: 0.5, 2: 5.0}
        viewer.connected = False
        wheel(viewer.canvases[1], 120)
        assert viewer.display_scales[1] == 0.5
        print('PASS: pointer routing, independent CH1/CH2 zoom, capture refresh, Ctrl+wheel, offline guard and queued hardware scales')
finally:
    root.destroy()