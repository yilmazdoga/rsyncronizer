"""Qt thread wrapper around engine.run_streaming-style calls.

One long-running engine subprocess at a time, its lines delivered to the UI
thread via signals. The engine's own lock makes an overlapping run exit 0
SKIPPED anyway; the GUI additionally disables its buttons while one streams.
"""

from PySide6.QtCore import QThread, Signal


class RunnerThread(QThread):
    line = Signal(str)
    finished_rc = Signal(int)

    def __init__(self, fn, parent=None):
        """fn: a callable taking on_line=callback and returning an exit code."""
        super().__init__(parent)
        self._fn = fn

    def run(self):
        rc = self._fn(on_line=self.line.emit)
        self.finished_rc.emit(rc)
