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
    QStackedWidget,
    QVBoxLayout,
    QWidget,
    QWizard,
    QWizardPage,
)

from . import engine
from .runner_thread import RunnerThread
from .theme import MUTED, WARN

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
        self.cloud_radio = QRadioButton(
            "A cloud service — S3, Google Drive, OneDrive or Dropbox (runs on a schedule)")
        self.ssh_radio.setChecked(True)
        group = QButtonGroup(self)
        group.addButton(self.ssh_radio)
        group.addButton(self.drive_radio)
        group.addButton(self.cloud_radio)

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

        # One panel per destination kind, in a stack. Flattening every field
        # of every kind into a single column and enable/disable-ing them worked
        # for two kinds; it does not survive a third.
        self.ssh_panel = QWidget()
        ssh_lay = QVBoxLayout(self.ssh_panel)
        ssh_lay.setContentsMargins(0, 0, 0, 0)
        ssh_lay.addWidget(QLabel("    Host:"))
        ssh_lay.addWidget(self.host)
        ssh_lay.addWidget(QLabel("    Username:"))
        ssh_lay.addWidget(self.user)
        ssh_lay.addWidget(QLabel("    Destination path:"))
        ssh_lay.addWidget(self.ssh_dest)
        ssh_lay.addWidget(self.create_dest)
        self.keys_btn = QPushButton("Set up SSH key access…")
        self.keys_btn.clicked.connect(self._setup_keys)
        ssh_lay.addWidget(self.keys_btn)

        self.drive_panel = QWidget()
        drive_lay = QVBoxLayout(self.drive_panel)
        drive_lay.setContentsMargins(0, 0, 0, 0)
        drive_lay.addWidget(QLabel("    Volume (must be mounted now):"))
        drive_lay.addWidget(self.volume)
        drive_lay.addWidget(QLabel("    Folder ON the drive:"))
        drive_lay.addWidget(self.drive_dest)

        self.cloud_panel = QWidget()
        cloud_lay = QVBoxLayout(self.cloud_panel)
        cloud_lay.setContentsMargins(0, 0, 0, 0)
        # rclone is optional, so this is a page-level message rather than the
        # main window's global banner -- a permanent red bar for a dependency
        # most users never need trains people to ignore banners.
        self.rclone_warn = QLabel()
        self.rclone_warn.setWordWrap(True)
        self.rclone_warn.setTextInteractionFlags(Qt.TextSelectableByMouse)
        self.rclone_warn.setStyleSheet(f"color: {WARN};")
        self.copy_cmd_btn = QPushButton("Copy install command")
        self.copy_cmd_btn.clicked.connect(self._copy_install_cmd)
        cloud_lay.addWidget(self.rclone_warn)
        cloud_lay.addWidget(self.copy_cmd_btn)

        self.cloud_remote = QComboBox()
        self.cloud_remote.currentIndexChanged.connect(self._cloud_remote_changed)
        self.connect_btn = QPushButton("Connect an account…")
        self.connect_btn.clicked.connect(self._connect_cloud)
        self.cloud_bucket = QLineEdit()
        self.cloud_bucket.setPlaceholderText("bucket name (required for S3)")
        self.cloud_bucket_label = QLabel("    Bucket:")
        self.cloud_dest = QLineEdit()
        self.cloud_dest.setPlaceholderText(f"Rsyncronizer/{host}")
        self.create_cloud_dest = QCheckBox("Create the destination folder if it does not exist")
        self.create_cloud_dest.setChecked(True)
        self.cloud_note = QLabel()
        self.cloud_note.setWordWrap(True)
        self.cloud_note.setStyleSheet(f"color: {MUTED};")

        cloud_lay.addWidget(QLabel("    Account:"))
        cloud_lay.addWidget(self.cloud_remote)
        cloud_lay.addWidget(self.connect_btn)
        cloud_lay.addWidget(self.cloud_bucket_label)
        cloud_lay.addWidget(self.cloud_bucket)
        cloud_lay.addWidget(QLabel("    Folder inside the account:"))
        cloud_lay.addWidget(self.cloud_dest)
        cloud_lay.addWidget(self.create_cloud_dest)
        cloud_lay.addWidget(self.cloud_note)

        self.stack = QStackedWidget()
        self.stack.addWidget(self.ssh_panel)      # index 0
        self.stack.addWidget(self.drive_panel)    # index 1
        self.stack.addWidget(self.cloud_panel)    # index 2

        lay = QVBoxLayout(self)
        lay.addWidget(self.ssh_radio)
        lay.addWidget(self.drive_radio)
        lay.addWidget(self.cloud_radio)
        lay.addSpacing(8)
        lay.addWidget(self.stack)
        lay.addStretch(1)

        for w in (self.ssh_radio, self.drive_radio, self.cloud_radio):
            w.toggled.connect(self._sync)
        for w in (self.host, self.ssh_dest, self.drive_dest,
                  self.cloud_dest, self.cloud_bucket):
            w.textChanged.connect(self.completeChanged)
        self.volume.editTextChanged.connect(self.completeChanged)
        self._sync()

    def kind(self) -> str:
        """'ssh' | 'local' | 'cloud' -- the one place the radios are read."""
        if self.drive_radio.isChecked():
            return "local"
        if self.cloud_radio.isChecked():
            return "cloud"
        return "ssh"

    def initializePage(self):
        # Deliberately NOT in __init__: listing rclone remotes is a subprocess,
        # and BackupWizard() is constructed in tests and on every window open.
        self._refresh_cloud()

    def _refresh_cloud(self, select: str | None = None):
        have = engine.rclone_path() is not None
        self.rclone_warn.setVisible(not have)
        self.copy_cmd_btn.setVisible(not have)
        if not have:
            self.rclone_warn.setText(
                "rclone is not installed. Rsyncronizer uses it to talk to cloud "
                "services.\n\n" + engine.rclone_install_hint()
                + "\n\nThen reopen this page."
            )
        current = select or self.selected_remote_name()
        self.cloud_remote.blockSignals(True)
        self.cloud_remote.clear()
        remotes = engine.list_cloud_remotes() if have else []
        for remote in remotes:
            label = engine.CLOUD_TYPES.get(remote["type"], remote["type"])
            self.cloud_remote.addItem(f"{remote['name']}  ({label})", remote)
        if not remotes:
            self.cloud_remote.addItem("— no accounts connected —", None)
        if current:
            for i in range(self.cloud_remote.count()):
                data = self.cloud_remote.itemData(i)
                if data and data.get("name") == current:
                    self.cloud_remote.setCurrentIndex(i)
                    break
        self.cloud_remote.blockSignals(False)
        self._cloud_remote_changed()

    def selected_remote(self) -> dict | None:
        return self.cloud_remote.currentData()

    def selected_remote_name(self) -> str:
        remote = self.selected_remote()
        return remote["name"] if remote else ""

    def _cloud_remote_changed(self, *_):
        remote = self.selected_remote()
        rtype = remote["type"] if remote else ""
        is_s3 = rtype == "s3"
        self.cloud_bucket.setVisible(is_s3)
        self.cloud_bucket_label.setVisible(is_s3)
        note = engine.CLOUD_PROVIDER_NOTES.get(rtype, "")
        self.cloud_note.setText((note + " " if note else "") + engine.CLOUD_NOTE_ALL)
        self.completeChanged.emit()

    def _copy_install_cmd(self):
        from PySide6.QtWidgets import QApplication

        cmd = "brew install rclone" if sys.platform == "darwin" else "sudo apt install rclone"
        QApplication.clipboard().setText(cmd)
        self.copy_cmd_btn.setText(f"Copied: {cmd}")

    def _connect_cloud(self):
        from .dialogs import CloudConnectDialog

        dlg = CloudConnectDialog(self.window())
        if dlg.exec():
            self._refresh_cloud(select=dlg.remote_name)
        else:
            self._refresh_cloud()

    def _setup_keys(self):
        from .dialogs import SshSetupDialog

        host = self.host.text().strip()
        user = self.user.text().strip()
        target = f"{user}@{host}" if user and host else host
        SshSetupDialog(target, self.window()).exec()

    def _sync(self):
        self.stack.setCurrentIndex({"ssh": 0, "local": 1, "cloud": 2}[self.kind()])
        self.completeChanged.emit()

    def isComplete(self) -> bool:
        kind = self.kind()
        if kind == "ssh":
            return bool(self.host.text().strip()) and bool(self.ssh_dest.text().strip())
        if kind == "local":
            return bool(self.volume.currentText().strip())
        # Cloud. Blocking Next while rclone is missing is deliberate: it stops
        # the user reaching a run that is certain to fail.
        remote = self.selected_remote()
        if engine.rclone_path() is None or remote is None:
            return False
        if remote["type"] == "s3" and not self.cloud_bucket.text().strip():
            return False
        return True


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
        # Cloud backups run on a clock like SSH ones; only a plugged-in drive
        # gets the connect-trigger chain. Keyed on 'is it the drive', never on
        # 'is it ssh' -- those stopped being the same question.
        scheduled = self._dest.kind() != "local"
        for w in (self.schedule_on, self.preset, self.custom):
            w.setVisible(scheduled)
        for w in (self.trigger_on, self.poll_radio, self.launchd_radio, self.linux_note):
            w.setVisible(not scheduled and (w is not self.poll_radio and w is not self.launchd_radio or sys.platform == "darwin"))
        if not scheduled and sys.platform != "darwin":
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
        extra = ""
        if form["dest_kind"] == "ssh":
            remote = f"{form['user']}@{form['host']}" if form.get("user") else form["host"]
            dest = f"{remote}:{form['dest_path']}"
        elif form["dest_kind"] == "cloud":
            dest = engine.cloud_dest_display(form)
            label = engine.CLOUD_TYPES.get(form.get("cloud_type", ""), form.get("cloud_type", ""))
            note = engine.CLOUD_PROVIDER_NOTES.get(form.get("cloud_type", ""), "")
            extra = (f"Cloud account : {form['cloud_remote']}  ({label})\n\n"
                     + (note + "\n" if note else "") + engine.CLOUD_NOTE_ALL + "\n")
        else:
            dest = form["dest_path"] or form["volume_root"]
        lands = f"{dest}/{os.path.basename(resolved)}/"
        self.summary.setText(
            f"You entered   : {src}\n"
            f"Resolves to   : {resolved}\n"
            f"Will land as  : {lands}\n"
            + (f"{extra}\n" if extra else "\n")
            + "Nothing at the destination is deleted by scheduled or plain runs."
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
        kind = self.dest.kind()
        form: dict = {
            "name": self.basics.name.text().strip(),
            "source": self.basics.source.text().strip(),
            "dest_kind": kind,
        }
        # Exactly one branch contributes keys, so switching the radio back can
        # never leave a stale field from the kind you moved away from.
        if kind == "ssh":
            form["host"] = self.dest.host.text().strip()
            form["user"] = self.dest.user.text().strip()
            form["dest_path"] = self.dest.ssh_dest.text().strip()
            form["create_dest"] = self.dest.create_dest.isChecked()
            self._add_schedule(form)
        elif kind == "cloud":
            remote = self.dest.selected_remote() or {}
            form["cloud_remote"] = remote.get("name", "")
            form["cloud_type"] = remote.get("type", "")
            form["cloud_bucket"] = (self.dest.cloud_bucket.text().strip()
                                    if remote.get("type") == "s3" else "")
            form["dest_path"] = (self.dest.cloud_dest.text().strip()
                                 or self.dest.cloud_dest.placeholderText())
            form["create_dest"] = self.dest.create_cloud_dest.isChecked()
            self._add_schedule(form)
        else:
            form["volume_root"] = self.dest.volume.currentText().strip()
            form["dest_path"] = self.dest.drive_dest.text().strip() \
                or self.dest.drive_dest.placeholderText()
            if self.sched.trigger_on.isChecked():
                form["install_trigger"] = True
                form["trigmode"] = "1" if self.sched.launchd_radio.isChecked() else "2"
        return form

    def _add_schedule(self, form: dict) -> None:
        """The cron chain, shared by the two clock-scheduled kinds."""
        if self.sched.schedule_on.isChecked():
            form["schedule"] = True
            form["schedule_choice"] = SCHEDULES[self.preset_index()][1]
            form["schedule_custom"] = self.sched.custom.text().strip()

    def preset_index(self) -> int:
        return self.sched.preset.currentIndex()
