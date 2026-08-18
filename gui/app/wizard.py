"""The new-backup wizard: Qt pages that mirror setup.sh's prompt order, then
a final page that streams the REAL setup.sh (headless) as its transcript.
All validation of consequence happens in the engine; the page-level checks
here only stop obviously-empty fields from wasting a run."""

from __future__ import annotations

import os
import re
import socket
import sys

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QButtonGroup,
    QCheckBox,
    QComboBox,
    QFileDialog,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QPlainTextEdit,
    QPushButton,
    QRadioButton,
    QVBoxLayout,
    QWizard,
    QWizardPage,
)

from . import engine
from .runner_thread import RunnerThread

NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")

SCHEDULES = [
    ("Daily at 02:00", "1"),
    ("Twice daily, 12:30 and 20:30", "2"),
    ("Hourly", "3"),
    ("Weekly, Sunday 03:00", "4"),
    ("Custom cron expression", "5"),
]


def _mounted_volumes() -> list[str]:
    """Candidate removable volumes, same locations setup.sh lists."""
    vols = []
    if sys.platform == "darwin":
        base = "/Volumes"
        if os.path.isdir(base):
            vols = [os.path.join(base, v) for v in sorted(os.listdir(base))]
    else:
        for base in ("/media", "/mnt", "/run/media"):
            if os.path.isdir(base):
                for root, dirs, _files in os.walk(base):
                    if root.count(os.sep) > 3:
                        dirs[:] = []
                        continue
                    for d in dirs:
                        vols.append(os.path.join(root, d))
    return [v for v in vols if os.path.ismount(v)]


class BasicsPage(QWizardPage):
    def __init__(self):
        super().__init__()
        self.setTitle("Backup name and source")
        self.name = QLineEdit()
        self.name.setPlaceholderText("e.g. documents-to-workstation")
        self.source = QLineEdit()
        self.source.setPlaceholderText("absolute, or relative to your home folder")
        browse = QPushButton("Browse…")
        browse.clicked.connect(self._browse)
        row = QHBoxLayout()
        row.addWidget(self.source)
        row.addWidget(browse)
        lay = QVBoxLayout(self)
        lay.addWidget(QLabel("Name (letters, digits, dot, underscore, hyphen):"))
        lay.addWidget(self.name)
        lay.addWidget(QLabel("Source folder on THIS machine:"))
        lay.addLayout(row)
        self.name.textChanged.connect(self.completeChanged)
        self.source.textChanged.connect(self.completeChanged)

    def _browse(self):
        path = QFileDialog.getExistingDirectory(self, "Choose the source folder", os.path.expanduser("~"))
        if path:
            self.source.setText(path)

    def isComplete(self) -> bool:
        return bool(NAME_RE.match(self.name.text())) and bool(self.source.text().strip())


class DestinationPage(QWizardPage):
    def __init__(self):
        super().__init__()
        self.setTitle("Destination")
        self.ssh_radio = QRadioButton("Another machine over SSH (runs on a schedule)")
        self.drive_radio = QRadioButton("A drive plugged into this machine (runs when you connect it)")
        self.ssh_radio.setChecked(True)
        group = QButtonGroup(self)
        group.addButton(self.ssh_radio)
        group.addButton(self.drive_radio)

        self.host = QLineEdit()
        self.host.setPlaceholderText("~/.ssh/config alias, hostname or IP — key-based auth only")
        self.user = QLineEdit()
        self.user.setPlaceholderText("leave blank to let ~/.ssh/config decide")
        self.ssh_dest = QLineEdit()
        self.ssh_dest.setPlaceholderText("folder your source will be placed INSIDE")
        self.create_dest = QCheckBox("Create the destination folder if it does not exist")
        self.create_dest.setChecked(True)

        self.volume = QComboBox()
        self.volume.setEditable(True)
        for v in _mounted_volumes():
            self.volume.addItem(v)
        self.drive_dest = QLineEdit()
        host = socket.gethostname().split(".")[0] or "backup"
        self.volume.editTextChanged.connect(
            lambda text: self.drive_dest.setPlaceholderText(f"{text}/{host}" if text else "")
        )

        lay = QVBoxLayout(self)
        lay.addWidget(self.ssh_radio)
        lay.addWidget(QLabel("    Host:"))
        lay.addWidget(self.host)
        lay.addWidget(QLabel("    Username:"))
        lay.addWidget(self.user)
        lay.addWidget(QLabel("    Destination path:"))
        lay.addWidget(self.ssh_dest)
        lay.addWidget(self.create_dest)
        self.keys_btn = QPushButton("Set up SSH key access…")
        self.keys_btn.clicked.connect(self._setup_keys)
        lay.addWidget(self.keys_btn)
        lay.addSpacing(12)
        lay.addWidget(self.drive_radio)
        lay.addWidget(QLabel("    Volume (must be mounted now):"))
        lay.addWidget(self.volume)
        lay.addWidget(QLabel("    Folder ON the drive:"))
        lay.addWidget(self.drive_dest)

        for w in (self.ssh_radio, self.drive_radio):
            w.toggled.connect(self._sync)
        for w in (self.host, self.ssh_dest, self.drive_dest):
            w.textChanged.connect(self.completeChanged)
        self.volume.editTextChanged.connect(self.completeChanged)
        self._sync()

    def _setup_keys(self):
        from .dialogs import SshSetupDialog

        host = self.host.text().strip()
        user = self.user.text().strip()
        target = f"{user}@{host}" if user and host else host
        SshSetupDialog(target, self.window()).exec()

    def _sync(self):
        ssh = self.ssh_radio.isChecked()
        for w in (self.host, self.user, self.ssh_dest, self.create_dest, self.keys_btn):
            w.setEnabled(ssh)
        for w in (self.volume, self.drive_dest):
            w.setEnabled(not ssh)
        self.completeChanged.emit()

    def isComplete(self) -> bool:
        if self.ssh_radio.isChecked():
            return bool(self.host.text().strip()) and bool(self.ssh_dest.text().strip())
        return bool(self.volume.currentText().strip())


class SchedulePage(QWizardPage):
    def __init__(self, dest_page: DestinationPage):
        super().__init__()
        self._dest = dest_page
        self.setTitle("Automatic runs")

        # SSH: cron schedule.
        self.schedule_on = QCheckBox("Schedule this backup with cron")
        self.schedule_on.setChecked(True)
        self.preset = QComboBox()
        for label, _choice in SCHEDULES:
            self.preset.addItem(label)
        self.custom = QLineEdit()
        self.custom.setPlaceholderText("5 fields, e.g. 0 2 * * *  (or @daily)")
        self.custom.setEnabled(False)
        self.preset.currentIndexChanged.connect(
            lambda i: self.custom.setEnabled(SCHEDULES[i][1] == "5")
        )

        # Drive: connect trigger.
        self.trigger_on = QCheckBox("Install the drive-connect trigger")
        self.trigger_on.setChecked(True)
        self.poll_radio = QRadioButton("cron poll every 15 minutes (no new permission needed)")
        self.launchd_radio = QRadioButton("launchd agent (instant, but needs Full Disk Access for /bin/bash)")
        self.poll_radio.setChecked(True)
        self.linux_note = QLabel(
            "On Linux the trigger needs root (udev + systemd): the wizard only\n"
            "writes an installer script and shows you the sudo command to run."
        )

        lay = QVBoxLayout(self)
        lay.addWidget(self.schedule_on)
        lay.addWidget(self.preset)
        lay.addWidget(self.custom)
        lay.addWidget(self.trigger_on)
        if sys.platform == "darwin":
            lay.addWidget(self.poll_radio)
            lay.addWidget(self.launchd_radio)
        else:
            lay.addWidget(self.linux_note)

    def initializePage(self):
        ssh = self._dest.ssh_radio.isChecked()
        for w in (self.schedule_on, self.preset, self.custom):
            w.setVisible(ssh)
        for w in (self.trigger_on, self.poll_radio, self.launchd_radio, self.linux_note):
            w.setVisible(not ssh and (w is not self.poll_radio and w is not self.launchd_radio or sys.platform == "darwin"))
        if not ssh and sys.platform != "darwin":
            self.linux_note.setVisible(True)


class ReviewPage(QWizardPage):
    def __init__(self, wizard: "BackupWizard"):
        super().__init__()
        self._wiz = wizard
        self.setTitle("Review")
        self.summary = QLabel()
        self.summary.setTextFormat(Qt.PlainText)
        self.summary.setWordWrap(True)
        note = QLabel(
            "Continuing runs the real setup wizard with these answers.\n"
            "It re-validates everything and its transcript is shown next."
        )
        lay = QVBoxLayout(self)
        lay.addWidget(self.summary)
        lay.addStretch(1)
        lay.addWidget(note)

    def initializePage(self):
        form = self._wiz.form_state()
        src = form["source"]
        # Display-only mirror of the engine's resolve_path: the engine
        # recomputes this authoritatively when setup.sh runs.
        resolved = src if os.path.isabs(src) else os.path.join(os.path.expanduser("~"), src)
        resolved = resolved.rstrip("/") or "/"
        if form["dest_kind"] == "ssh":
            remote = f"{form['user']}@{form['host']}" if form.get("user") else form["host"]
            dest = f"{remote}:{form['dest_path']}"
        else:
            dest = form["dest_path"] or form["volume_root"]
        lands = f"{dest}/{os.path.basename(resolved)}/"
        self.summary.setText(
            f"You entered   : {src}\n"
            f"Resolves to   : {resolved}\n"
            f"Will land as  : {lands}\n\n"
            "Nothing at the destination is deleted by scheduled or plain runs."
        )


class TranscriptPage(QWizardPage):
    def __init__(self, wizard: "BackupWizard"):
        super().__init__()
        self._wiz = wizard
        self.setTitle("Setup transcript")
        self.out = QPlainTextEdit()
        self.out.setReadOnly(True)
        self.out.setStyleSheet("font-family: Menlo, monospace;")
        self.state = QLabel("Running setup…")
        lay = QVBoxLayout(self)
        lay.addWidget(self.out)
        lay.addWidget(self.state)
        self._done = False
        self._thread = None

    def initializePage(self):
        self._done = False
        self.out.clear()
        answers = engine.build_answers(self._wiz.form_state())
        self._thread = RunnerThread(lambda on_line: engine.run_setup(answers, on_line=on_line), self)
        self._thread.line.connect(self.out.appendPlainText)
        self._thread.finished_rc.connect(self._finished)
        self._thread.start()

    def _finished(self, rc: int):
        self._done = True
        if rc == 0:
            self.state.setText("Done — the backup is configured.")
        else:
            self.state.setText(
                f"setup.sh exited {rc} — nothing may have been configured. "
                "The transcript above says why."
            )
        self.completeChanged.emit()

    def isComplete(self) -> bool:
        return self._done


class BackupWizard(QWizard):
    """Collect answers, then drive the real setup.sh."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("New backup")
        self.setWizardStyle(QWizard.ModernStyle)
        self.basics = BasicsPage()
        self.dest = DestinationPage()
        self.sched = SchedulePage(self.dest)
        self.addPage(self.basics)
        self.addPage(self.dest)
        self.addPage(self.sched)
        self.addPage(ReviewPage(self))
        self.addPage(TranscriptPage(self))
        self.setMinimumSize(640, 480)
        # The forward action carries the neon fill, matching the main window.
        for role in (QWizard.NextButton, QWizard.FinishButton, QWizard.CommitButton):
            btn = self.button(role)
            if btn is not None:
                btn.setObjectName("primary")

    def form_state(self) -> dict:
        ssh = self.dest.ssh_radio.isChecked()
        form: dict = {
            "name": self.basics.name.text().strip(),
            "source": self.basics.source.text().strip(),
            "dest_kind": "ssh" if ssh else "local",
        }
        if ssh:
            form["host"] = self.dest.host.text().strip()
            form["user"] = self.dest.user.text().strip()
            form["dest_path"] = self.dest.ssh_dest.text().strip()
            form["create_dest"] = self.dest.create_dest.isChecked()
            if self.sched.schedule_on.isChecked():
                idx = self.preset_index()
                form["schedule"] = True
                form["schedule_choice"] = SCHEDULES[idx][1]
                form["schedule_custom"] = self.sched.custom.text().strip()
        else:
            form["volume_root"] = self.dest.volume.currentText().strip()
            form["dest_path"] = self.dest.drive_dest.text().strip() \
                or self.dest.drive_dest.placeholderText()
            if self.sched.trigger_on.isChecked():
                form["install_trigger"] = True
                form["trigmode"] = "1" if self.sched.launchd_radio.isChecked() else "2"
        return form

    def preset_index(self) -> int:
        return self.sched.preset.currentIndex()
