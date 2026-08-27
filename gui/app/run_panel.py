"""The run panel: activity bar + live counters, raw console behind a dropdown.

Honesty rule: no invented percentages. openrsync reports no byte progress and
rsync announces only what it transfers, so the bar is an activity indicator and
the numbers beside it are real: elapsed time, ≈ files seen, the current file,
and last run's total as context.
"""

from __future__ import annotations

from PySide6.QtCore import Qt, QTimer
from PySide6.QtWidgets import (
    QHBoxLayout,
    QLabel,
    QPlainTextEdit,
    QProgressBar,
    QToolButton,
    QVBoxLayout,
    QWidget,
)

from .theme import BAD, GOOD, MUTED

MONO = "font-family: Menlo, 'DejaVu Sans Mono', monospace; font-size: 12px;"

# rsync/rclone/engine chatter that must not count as a transferred file.
_CHATTER_PREFIXES = (
    "sending incremental file list",
    "building file list",
    "receiving file list",
    "sent ",
    "total size is",
    "Number of ",
    "Total ",
    "File list size",
    "Matched data",
    "Unmatched data",
    "Transfer starting",
    "fake-rsync",
    "fake-rclone",
    # rclone's end-of-run stats block. Six lines, not one: --stats-one-line
    # collapses the block to a bytes-only summary and drops the file COUNT the
    # engine parses FILES=/TOTAL_FILES= out of.
    "Transferred:",
    "Checks:",
    "Deleted:",
    "Renamed:",
    "Elapsed time:",
    "Errors:",
    "RESULT:",
    "ERROR:",
    "WARNING:",
    "=====",
    "-----",
)


def is_file_line(line: str) -> bool:
    """True when a stream line most likely names a transferred file."""
    text = line.strip()
    if not text:
        return False
    for prefix in _CHATTER_PREFIXES:
        if text.startswith(prefix):
            return False
    # Engine log lines are `key      : value`.
    head = text[:12]
    if " : " in head or head.endswith(":"):
        return False
    return True


class Console(QWidget):
    """A 'Show output' dropdown wrapping a read-only console pane."""

    def __init__(self, parent=None, label: str = "Show output"):
        super().__init__(parent)
        self.toggle = QToolButton()
        self.toggle.setText(label)
        self.toggle.setArrowType(Qt.RightArrow)
        self.toggle.setToolButtonStyle(Qt.ToolButtonTextBesideIcon)
        self.toggle.setCheckable(True)
        self.toggle.setStyleSheet(
            "QToolButton { border: none; background: transparent; color: #9aa0b5; }"
        )
        self.toggle.setCursor(Qt.PointingHandCursor)
        self.pane = QPlainTextEdit()
        self.pane.setReadOnly(True)
        self.pane.setStyleSheet(MONO)
        self.pane.setVisible(False)
        self.pane.setMinimumHeight(140)
        self.toggle.toggled.connect(self._flip)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.addWidget(self.toggle)
        lay.addWidget(self.pane)

    def _flip(self, checked: bool):
        self.pane.setVisible(checked)
        self.toggle.setArrowType(Qt.DownArrow if checked else Qt.RightArrow)

    def append(self, line: str):
        self.pane.appendPlainText(line)

    def clear(self):
        self.pane.clear()


class RunPanel(QWidget):
    """Bottom-of-window run status: state, activity bar, counters, console."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.state = QLabel("No run active.")
        self.state.setStyleSheet(f"color: {MUTED};")
        self.bar = QProgressBar()
        self.bar.setRange(0, 1)
        self.bar.setValue(0)
        self.bar.setTextVisible(False)
        self.bar.setFixedHeight(8)
        self.counters = QLabel("")
        self.counters.setStyleSheet(f"color: {MUTED}; {MONO}")
        self.current = QLabel("")
        self.current.setStyleSheet(f"color: {MUTED}; {MONO}")
        self.current.setTextFormat(Qt.PlainText)
        self.console = Console()

        top = QHBoxLayout()
        top.addWidget(self.state)
        top.addStretch(1)
        top.addWidget(self.counters)
        lay = QVBoxLayout(self)
        lay.addLayout(top)
        lay.addWidget(self.bar)
        lay.addWidget(self.current)
        lay.addWidget(self.console)

        self._timer = QTimer(self)
        self._timer.setInterval(1000)
        self._timer.timeout.connect(self._tick)
        self._elapsed = 0
        self._files = 0
        self._total_hint = ""

    def begin(self, title: str, total_hint: str = ""):
        self.state.setText(title)
        self.state.setStyleSheet("font-weight: bold;")
        self.bar.setRange(0, 0)          # indeterminate: activity, not a lie
        self._elapsed = 0
        self._files = 0
        self._total_hint = total_hint
        self.console.clear()
        self.current.setText("")
        self._update_counters()
        self._timer.start()

    def feed(self, line: str):
        self.console.append(line)
        if is_file_line(line):
            self._files += 1
            self.current.setText(line.strip()[-90:])
            self._update_counters()

    def finish(self, rc: int):
        self._timer.stop()
        self.bar.setRange(0, 1)
        self.bar.setValue(1 if rc in (0, 24) else 0)
        colour = GOOD if rc in (0, 24) else BAD
        self.state.setText(f"Finished — exit {rc}")
        self.state.setStyleSheet(f"font-weight: bold; color: {colour};")
        self.current.setText("")

    def _tick(self):
        self._elapsed += 1
        self._update_counters()

    def _update_counters(self):
        mins, secs = divmod(self._elapsed, 60)
        text = f"{mins:d}:{secs:02d}   ≈ {self._files} files"
        if self._total_hint:
            text += f"   (last run: {self._total_hint} total)"
        self.counters.setText(text)
