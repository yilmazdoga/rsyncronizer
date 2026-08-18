"""Status dashboard.

Grouped sections: a LOCAL box, then one box per remote server (label as the
header), each holding collapsible per-backup cards. Refresh lifecycle: a 30 s
timer plus after-run refreshes; the timer never fires while a run is active or
a modal is open; every async remote fetch carries a generation token and stale
results are dropped — so no callback can ever touch a destroyed card.

The sync-deletions dialog is staged: Scan → will-delete list → typed phrase →
re-verify → transfer, with the raw stream behind a console dropdown. All
confirmation logic stays in the engine (local or remote); the dialog only
forwards what the user types.
"""

from __future__ import annotations

from PySide6.QtCore import Qt, QThread, QTimer, Signal
from PySide6.QtWidgets import (
    QApplication,
    QDialog,
    QFrame,
    QGridLayout,
    QGroupBox,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QListWidget,
    QProgressBar,
    QPushButton,
    QScrollArea,
    QToolButton,
    QVBoxLayout,
    QWidget,
)

from . import engine
from .dialogs import IgnoreDialog
from .run_panel import MONO, Console
from .runner_thread import RunnerThread
from .theme import BAD, GOOD, MUTED, NEON_CYAN, TEXT, WARN


def _state_text(b: dict) -> str:
    if b.get("NEVER_RAN") == "1":
        return "NEVER RAN"
    verdict = b.get("VERDICT", "?")
    return verdict.split(" -- ")[0].split(" (")[0]


def _state_colour(b: dict) -> str:
    if b.get("NEVER_RAN") == "1":
        return MUTED
    if b.get("RC") in ("0", "24"):
        if b.get("STALE") in ("1", "2") or b.get("BOOTSTRAP_ALERT") == "1":
            return WARN
        return GOOD
    return BAD


class RemoteFetchThread(QThread):
    """Fetch one remote's porcelain off the UI thread."""

    result = Signal(int, str, object)      # generation, label, payload dict

    def __init__(self, generation: int, label: str, parent=None):
        super().__init__(parent)
        self._gen = generation
        self._label = label

    def run(self):
        rc, header, backups, error = engine.remote_status(self._label)
        self.result.emit(self._gen, self._label,
                         {"rc": rc, "header": header, "backups": backups, "error": error})


class RunDialog(QDialog):
    """Dry run | Run | Run with sync deletions — the last one staged."""

    PH_SCAN = "Scanning the destination for entries to delete…"
    PH_CONFIRM = "Review the list, then type the phrase to proceed."
    PH_RECHECK = "Re-verifying the list against the source…"
    PH_RUN = "Transferring — deletions run only after the transfer completes."

    def __init__(self, name: str, parent=None, runner_factory=None,
                 remote_label: str | None = None):
        super().__init__(parent)
        self._name = name
        self._remote = remote_label
        self._factory = runner_factory or (lambda: engine.sync_deletions_runner(name))
        self.choice: str | None = None
        self._runner: engine.PtyRunner | None = None
        self._thread: RunnerThread | None = None
        self._finished_rc: int | None = None
        self._confirm_sent = False
        where = f"{name} on {remote_label}" if remote_label else name
        self.setWindowTitle(f"Run {where}")
        self.setMinimumWidth(600)

        lay = QVBoxLayout(self)

        self._pick = QWidget()
        pick_lay = QVBoxLayout(self._pick)
        pick_lay.setContentsMargins(0, 0, 0, 0)
        pick_lay.addWidget(QLabel(f"How should <b>{where}</b> run?"))
        dry_btn = QPushButton("Dry run — show what would transfer, change nothing")
        run_btn = QPushButton("Run — normal backup, never deletes")
        run_btn.setObjectName("primary")
        del_btn = QPushButton("Run with sync deletions — remove destination files absent from the source")
        del_btn.setObjectName("danger")
        for b in (dry_btn, run_btn, del_btn):
            pick_lay.addWidget(b)
        dry_btn.clicked.connect(lambda: self._direct("dry"))
        run_btn.clicked.connect(lambda: self._direct("run"))
        del_btn.clicked.connect(self._start_sync_deletions)
        lay.addWidget(self._pick)

        # Staged sync-deletions surface (hidden until chosen).
        self._phase = QLabel(self.PH_SCAN)
        self._phase.setStyleSheet("font-weight: bold;")
        self._busy = QProgressBar()
        self._busy.setRange(0, 0)
        self._busy.setTextVisible(False)
        self._busy.setFixedHeight(6)
        self._list = QListWidget()
        self._list.setStyleSheet(MONO)
        self._list.setMinimumHeight(180)
        self._count = QLabel("")
        self._count.setStyleSheet(f"color: {MUTED};")
        self._entry = QLineEdit()
        self._entry.setPlaceholderText("type I confirm to delete — anything else aborts")
        self._entry.setEnabled(False)
        self._entry.returnPressed.connect(self._send_reply)
        self._send = QPushButton("Send")
        self._send.setEnabled(False)
        self._send.clicked.connect(self._send_reply)
        entry_row = QHBoxLayout()
        entry_row.addWidget(self._entry)
        entry_row.addWidget(self._send)
        self._entry_holder = QWidget()
        self._entry_holder.setLayout(entry_row)
        self._console = Console(label="Show raw output")
        for w in (self._phase, self._busy, self._list, self._count,
                  self._entry_holder, self._console):
            w.setVisible(False)
            lay.addWidget(w)

        close_row = QHBoxLayout()
        close_row.addStretch(1)
        self._close = QPushButton("Close")
        self._close.clicked.connect(self.reject)
        close_row.addWidget(self._close)
        lay.addLayout(close_row)

    def _direct(self, choice: str):
        self.choice = choice
        self.accept()

    # -- sync deletions ----------------------------------------------------
    def _start_sync_deletions(self):
        self._pick.setVisible(False)
        for w in (self._phase, self._busy, self._list, self._count,
                  self._entry_holder, self._console):
            w.setVisible(True)
        where = f"{self._name} on {self._remote}" if self._remote else self._name
        self.setWindowTitle(f"Sync deletions — {where}")
        self._runner = self._factory()
        self._thread = RunnerThread(self._runner.run, self)
        self._thread.line.connect(self._on_line)
        self._thread.finished_rc.connect(self._on_finished)
        self._thread.start()

    def _on_line(self, line: str):
        self._console.append(line)
        text = line.strip()
        if "will delete: " in text:
            self._list.addItem(text.split("will delete: ", 1)[1])
            return
        if engine.SYNC_DELETIONS_PROMPT in text:
            n = self._list.count()
            self._phase.setText(self.PH_CONFIRM)
            self._busy.setVisible(False)
            self._count.setText(f"{n} entries would be deleted from the destination.")
            self._entry.setEnabled(True)
            self._send.setEnabled(True)
            self._entry.setFocus()
            return
        if engine.SYNC_DELETIONS_CONFIRMED in text:
            self._phase.setText(self.PH_RUN)
            return
        if "nothing to prune" in text:
            self._phase.setText("Nothing to delete — continuing as a normal backup run.")
            return
        if "LIST CHANGED" in text:
            self._phase.setText("The list changed after confirmation — aborted, nothing deleted.")

    def _send_reply(self):
        if self._runner is None or not self._entry.isEnabled():
            return
        text = self._entry.text()
        self._console.append(f"> {text}")
        self._entry.setEnabled(False)
        self._send.setEnabled(False)
        self._confirm_sent = True
        self._phase.setText(self.PH_RECHECK)
        self._busy.setVisible(True)
        self._runner.send(text + "\n")

    def _on_finished(self, rc: int):
        self._finished_rc = rc
        self._thread = None
        self._busy.setVisible(False)
        if rc == 0:
            self._phase.setText("Finished.")
            self._phase.setStyleSheet(f"font-weight: bold; color: {GOOD};")
        elif rc == 75:
            self._phase.setText("Aborted — nothing was transferred or deleted.")
            self._phase.setStyleSheet(f"font-weight: bold; color: {WARN};")
        elif rc == 255 and self._remote:
            self._phase.setText("Connection to the server lost — see the raw output. "
                                "Deletions only run after a complete transfer.")
            self._phase.setStyleSheet(f"font-weight: bold; color: {BAD};")
        else:
            self._phase.setText(f"Failed (exit {rc}) — see the raw output.")
            self._phase.setStyleSheet(f"font-weight: bold; color: {BAD};")
        self._entry.setEnabled(False)
        self._send.setEnabled(False)

    def reject(self):
        # Closing mid-run: an empty reply is a decline at the engine's prompt.
        if self._runner is not None and self._thread is not None:
            self._runner.send("\n")
            self._thread.wait(3000)
            if self._thread is not None and self._thread.isRunning():
                self._runner.terminate()
                self._thread.wait(2000)
        super().reject()


class BackupCard(QFrame):
    """Collapsed: state + last run + schedule + expand arrow.
    Expanded: details grid + Run manually (+ local-only Delete/ignores)."""

    def __init__(self, data: dict, view: "StatusView", remote_label: str | None = None,
                 remote_display: str | None = None):
        super().__init__()
        self._view = view
        self._data = data
        self._name = data.get("BACKUP", "")
        self._remote = remote_label
        # What the UI SAYS: the machine name, not the registration label.
        self._remote_display = remote_display or remote_label
        self.setObjectName("card")
        self.setStyleSheet(
            "QFrame#card { background: #1a1d26; border: 1px solid #2a2e3d;"
            " border-radius: 10px; }"
        )
        lay = QVBoxLayout(self)
        lay.setContentsMargins(14, 10, 14, 10)

        header = QHBoxLayout()
        name_lbl = QLabel(self._name)
        name_lbl.setStyleSheet(f"font-weight: bold; font-size: 14px; color: {NEON_CYAN};")
        state = QLabel(_state_text(data))
        state.setStyleSheet(f"font-weight: bold; color: {_state_colour(data)}; padding-left: 8px;")
        when = engine.humanize_age(data.get("LAST_EPOCH", ""))
        last = QLabel(f"last run {when}" if when else "never ran")
        last.setStyleSheet(f"color: {MUTED};")
        sched = QLabel(engine.humanize_schedule(data))
        sched.setStyleSheet(f"color: {MUTED};")
        self.arrow = QToolButton()
        self.arrow.setArrowType(Qt.RightArrow)
        self.arrow.setStyleSheet("QToolButton { border: none; background: transparent; }")
        self.arrow.setCursor(Qt.PointingHandCursor)
        self.arrow.clicked.connect(self.toggle)
        header.addWidget(name_lbl)
        header.addWidget(state)
        header.addStretch(1)
        header.addWidget(last)
        header.addSpacing(14)
        header.addWidget(sched)
        header.addSpacing(8)
        header.addWidget(self.arrow)
        lay.addLayout(header)

        self.details = QWidget()
        grid = QGridLayout(self.details)
        grid.setContentsMargins(2, 8, 2, 2)
        grid.setHorizontalSpacing(16)

        def row(r: int, label: str, value: str, colour: str = TEXT):
            key = QLabel(label)
            key.setStyleSheet(f"color: {MUTED}; {MONO}")
            val = QLabel(value)
            val.setStyleSheet(f"color: {colour}; {MONO}")
            val.setTextFormat(Qt.PlainText)
            val.setWordWrap(True)
            grid.addWidget(key, r, 0, Qt.AlignTop)
            grid.addWidget(val, r, 1)

        r = 0
        row(r, "source", data.get("SRC", "?")); r += 1
        row(r, "dest", data.get("DEST", "?")); r += 1
        if data.get("DRIVE"):
            drive = {"connected": "connected",
                     "unmarked": "mounted but unmarked (wrong drive?)",
                     "absent": "not connected"}.get(data["DRIVE"], data["DRIVE"])
            row(r, "drive", drive, GOOD if data["DRIVE"] == "connected" else WARN); r += 1
        if data.get("NEVER_RAN") != "1":
            row(r, "last run", f"{data.get('LAST_WHEN', '?')}  ({data.get('VERDICT', '')})"); r += 1
            row(r, "triggered by", data.get("TRIGGERED", "unknown")); r += 1
            row(r, "files moved", f"{data.get('FILES', '?')} transferred in {data.get('ELAPSED', '?')}s"); r += 1
            row(r, "files deleted",
                f"{data['DELETED']} (confirmed sync-deletions run)" if data.get("DELETED")
                else "0 — nothing is deleted without confirmation"); r += 1

        warns = []
        if data.get("SRC_MISSING") == "1":
            warns.append(("source folder is MISSING", BAD))
        if data.get("RUNNER_MISSING") == "1":
            warns.append(("cron points at a runner that no longer exists", BAD))
        if data.get("STALE") == "1":
            warns.append(("STALE: scheduled runs are not happening", BAD))
        if data.get("STALE") == "2":
            warns.append(("scheduled, but no successful run recorded yet", WARN))
        if data.get("WAITING") == "1":
            warns.append(("waiting: drive not connected", WARN))
        if data.get("BOOTSTRAP_ALERT") == "1":
            warns.append(("cron-bootstrap.log is not empty — something failed before logging", BAD))
        for text, colour in warns:
            w = QLabel(f"!! {text}")
            w.setStyleSheet(f"color: {colour}; font-weight: bold;")
            grid.addWidget(w, r, 0, 1, 2)
            r += 1

        self.run_btn = QPushButton("Run manually")
        self.run_btn.setObjectName("primary")
        self.run_btn.clicked.connect(self._run_manually)
        self.ignore_btn = QPushButton("Per-Schedule Ignore Rules")
        self.ignore_btn.clicked.connect(lambda: view.open_ignores(self._name))
        self.del_btn = QPushButton("Delete backup schedule")
        self.del_btn.setObjectName("danger")
        self.del_btn.clicked.connect(self._delete_schedule)
        btn_row = QHBoxLayout()
        btn_row.addWidget(self.run_btn)
        btn_row.addWidget(self.ignore_btn)
        btn_row.addStretch(1)
        btn_row.addWidget(self.del_btn)
        if self._remote is not None:
            # v0.1: remote cards run, but schedule removal and ignore editing
            # happen on the owning machine.
            self.del_btn.setVisible(False)
            self.ignore_btn.setVisible(False)
        grid.addLayout(btn_row, r, 0, 1, 2)

        self.details.setVisible(False)
        lay.addWidget(self.details)

    def toggle(self):
        expanded = self.details.isHidden()
        self.details.setVisible(expanded)
        self.arrow.setArrowType(Qt.DownArrow if expanded else Qt.RightArrow)

    def _run_manually(self):
        if self._remote is None:
            factory = None
        else:
            label = self._remote
            name = self._name
            factory = lambda: engine.remote_runner(label, "sync-deletions", name)  # noqa: E731
        dlg = RunDialog(self._name, self._view.window(),
                        runner_factory=factory, remote_label=self._remote_display)
        self._view.modal_guard(True)
        dlg.exec()
        self._view.modal_guard(False)
        if dlg.choice == "dry":
            self._view.start_run(self._name, dry=True, remote=self._remote,
                                 remote_display=self._remote_display,
                                 total_hint=self._data.get("TOTAL_FILES", ""))
        elif dlg.choice == "run":
            self._view.start_run(self._name, dry=False, remote=self._remote,
                                 remote_display=self._remote_display,
                                 total_hint=self._data.get("TOTAL_FILES", ""))
        elif dlg._finished_rc is not None:
            self._view.refresh()
            # A completed in-dialog sync-deletions run is a real run.
            self._view._maybe_support_nag()

    def _delete_schedule(self):
        from PySide6.QtWidgets import QMessageBox

        box = QMessageBox(self._view.window())
        box.setWindowTitle("Delete backup schedule")
        box.setText(f"Delete the backup schedule “{self._name}”?")
        box.setInformativeText(
            "This uninstalls its cron entry / drive-connect trigger and removes\n"
            "its configuration and logs on this machine.\n\n"
            "The backed-up data at the destination is NOT touched."
        )
        delete = box.addButton("Delete schedule", QMessageBox.DestructiveRole)
        cancel = box.addButton("Cancel", QMessageBox.RejectRole)
        box.setDefaultButton(cancel)
        box.exec()
        if box.clickedButton() is delete:
            self._view.delete_backup(self._name)


class StatusView(QWidget):
    """Grouped card list with the refresh lifecycle."""

    def __init__(self, run_panel, parent=None):
        super().__init__(parent)
        self._panel = run_panel
        self._thread: RunnerThread | None = None
        self._cards: list[BackupCard] = []
        self._gen = 0
        self._fetches: list[RemoteFetchThread] = []
        self._remote_slots: dict[str, QVBoxLayout] = {}
        self._modal_depth = 0

        self._area = QScrollArea()
        self._area.setWidgetResizable(True)
        self._area.setFrameShape(QFrame.NoFrame)
        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(self._area)

        # Auto-refresh replaces the old Refresh button. Never fires during a
        # run or while a modal is open (see _auto_refresh guards).
        self._timer = QTimer(self)
        self._timer.setInterval(30_000)
        self._timer.timeout.connect(self._auto_refresh)
        self._timer.start()

        self.refresh()

    # -- lifecycle guards --------------------------------------------------
    def modal_guard(self, entering: bool):
        self._modal_depth += 1 if entering else -1

    def _auto_refresh(self):
        if self._thread is not None or self._modal_depth > 0:
            return
        if QApplication.activeModalWidget() is not None:
            return
        self.refresh()

    # -- rendering ---------------------------------------------------------
    def refresh(self):
        self._gen += 1
        gen = self._gen
        rc, header, backups = engine.status()
        remotes = engine.list_remotes()

        inner = QWidget()
        lay = QVBoxLayout(inner)
        self._cards = []
        self._remote_slots = {}

        local_box = QGroupBox("LOCAL")
        local_lay = QVBoxLayout(local_box)
        if not backups:
            empty = QLabel("No backups on this machine yet — use “New backup”.")
            empty.setStyleSheet(f"color: {MUTED};")
            local_lay.addWidget(empty)
        else:
            for b in backups:
                card = BackupCard(b, self)
                self._cards.append(card)
                local_lay.addWidget(card)
        lay.addWidget(local_box)

        for remote in remotes:
            label = remote["label"]
            # Until the fetch lands, the best machine name we have is the
            # registration; _on_remote_result retitles with the REAL hostname.
            box = QGroupBox(engine.remote_title(remote["host"]))
            box_lay = QVBoxLayout(box)
            slot = QVBoxLayout()
            fetching = QLabel("Fetching status…")
            fetching.setStyleSheet(f"color: {MUTED};")
            slot.addWidget(fetching)
            box_lay.addLayout(slot)
            self._remote_slots[label] = {"slot": slot, "box": box,
                                         "host": remote["host"]}
            lay.addWidget(box)

            fetch = RemoteFetchThread(gen, label, self)
            fetch.result.connect(self._on_remote_result)
            self._fetches.append(fetch)
            fetch.start()

        lay.addStretch(1)
        self._area.setWidget(inner)
        self._set_buttons_enabled(self._thread is None)

    def _on_remote_result(self, gen: int, label: str, payload: dict):
        if gen != self._gen:
            return                      # stale generation: its widgets are gone
        entry = self._remote_slots.get(label)
        if entry is None:
            return
        slot = entry["slot"]
        # The fetched porcelain carries the machine's REAL hostname — that is
        # the name shown, with the registration (IP/alias) in parentheses
        # when they differ.
        display = engine.remote_title(entry["host"],
                                      payload["header"].get("HOSTNAME"))
        entry["box"].setTitle(display)
        while slot.count():
            item = slot.takeAt(0)
            w = item.widget()
            if w is not None:
                w.deleteLater()
        if payload["error"] or (payload["rc"] != 0 and not payload["backups"]):
            err = QLabel(f"!! {payload['error'] or 'unreachable'}")
            err.setStyleSheet(f"color: {BAD};")
            err.setWordWrap(True)
            slot.addWidget(err)
        elif not payload["backups"]:
            none = QLabel("No backups configured on that machine.")
            none.setStyleSheet(f"color: {MUTED};")
            slot.addWidget(none)
        else:
            machine = display.replace("REMOTE: ", "").split("  (")[0]
            for b in payload["backups"]:
                card = BackupCard(b, self, remote_label=label,
                                  remote_display=machine)
                self._cards.append(card)
                slot.addWidget(card)
        self._set_buttons_enabled(self._thread is None)

    def _set_buttons_enabled(self, enabled: bool):
        for card in self._cards:
            card.run_btn.setEnabled(enabled)
            card.del_btn.setEnabled(enabled)

    # -- actions -----------------------------------------------------------
    def open_ignores(self, preselect: str | None = None):
        _, _, backups = engine.status()
        dlg = IgnoreDialog([b["BACKUP"] for b in backups], preselect, self.window())
        self.modal_guard(True)
        dlg.exec()
        self.modal_guard(False)

    def start_run(self, name: str, dry: bool, remote: str | None = None,
                  remote_display: str | None = None, total_hint: str = ""):
        if self._thread is not None:
            return
        where = f"{name} on {remote_display or remote}" if remote else name
        self._panel.begin(f"Running {where}{' — dry run' if dry else ''}", total_hint)
        self._set_buttons_enabled(False)
        self._timer.stop()
        if remote is None:
            fn = lambda on_line: engine.run_backup(name, dry_run=dry, on_line=on_line)  # noqa: E731
        else:
            mode = "dry" if dry else "run"
            fn = lambda on_line: engine.remote_runner(remote, mode, name).run(on_line=on_line)  # noqa: E731
        self._thread = RunnerThread(fn, self)
        self._thread.line.connect(self._panel.feed)
        self._thread.finished_rc.connect(self._run_finished)
        self._thread.start()

    def _run_finished(self, rc: int):
        self._panel.finish(rc)
        self._thread = None
        self._timer.start()
        self.refresh()
        self._maybe_support_nag()

    def _maybe_support_nag(self):
        """Show the support reminder when the engine's counter says it is due.

        Called after a run finishes and after an in-dialog sync-deletions run;
        never from refresh()/_auto_refresh — no modal popping while the user
        is idle. delete_backup funnels through _run_finished too, which is
        harmless: deletions never increment the counter, so the dialog appears
        there only if scheduled runs already made it due."""
        if not engine.support_due():
            return
        from .dialogs import SupportDialog

        dlg = SupportDialog(self.window())
        self.modal_guard(True)
        dlg.exec()
        self.modal_guard(False)

    def delete_backup(self, name: str):
        if self._thread is not None:
            return
        self._panel.begin(f"Deleting schedule {name}")
        self._set_buttons_enabled(False)
        self._timer.stop()
        self._thread = RunnerThread(
            lambda on_line: engine.remove_backup(name, on_line=on_line), self
        )
        self._thread.line.connect(self._panel.feed)
        self._thread.finished_rc.connect(self._run_finished)
        self._thread.start()
