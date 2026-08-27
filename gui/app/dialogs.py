"""Secondary dialogs: SSH key setup, cloud account setup, add-remote,
ignore-rules editor.

All of them drive engine scripts; none contain logic of their own. The SSH
dialog forwards what the user types over the pty — a password prompt switches
the entry to masked mode and the reply is NEVER echoed into the visible
stream, logged, or stored."""

from __future__ import annotations

import os

from PySide6.QtWidgets import (
    QCheckBox,
    QComboBox,
    QDialog,
    QFormLayout,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMessageBox,
    QPlainTextEdit,
    QPushButton,
    QStackedWidget,
    QVBoxLayout,
    QWidget,
)

from . import engine
from .run_panel import MONO
from .runner_thread import RunnerThread
from .theme import BAD, GOOD, MUTED, WARN


class SshSetupDialog(QDialog):
    """Runs ssh-setup.sh [user@]host, forwarding prompts."""

    def __init__(self, target: str = "", parent=None):
        super().__init__(parent)
        self.setWindowTitle("Set up SSH key access")
        self.setMinimumWidth(560)
        self._runner: engine.PtyRunner | None = None
        self._thread: RunnerThread | None = None
        self._password_mode = False
        self.finished_rc: int | None = None

        lay = QVBoxLayout(self)
        row = QHBoxLayout()
        self.target = QLineEdit(target)
        self.target.setPlaceholderText("user@host  (e.g. alice@backup-server)")
        self.start_btn = QPushButton("Start")
        self.start_btn.setObjectName("primary")
        self.start_btn.clicked.connect(self._start)
        row.addWidget(self.target)
        row.addWidget(self.start_btn)
        lay.addLayout(row)

        self.stream = QPlainTextEdit()
        self.stream.setReadOnly(True)
        self.stream.setStyleSheet(MONO)
        self.stream.setMinimumHeight(220)
        lay.addWidget(self.stream)

        self.hint = QLabel("The password goes straight to ssh; it is never stored or shown.")
        self.hint.setStyleSheet(f"color: {MUTED};")
        lay.addWidget(self.hint)

        entry_row = QHBoxLayout()
        self.entry = QLineEdit()
        self.entry.setEnabled(False)
        self.entry.returnPressed.connect(self._send)
        self.send_btn = QPushButton("Send")
        self.send_btn.setEnabled(False)
        self.send_btn.clicked.connect(self._send)
        entry_row.addWidget(self.entry)
        entry_row.addWidget(self.send_btn)
        lay.addLayout(entry_row)

        close_row = QHBoxLayout()
        close_row.addStretch(1)
        close = QPushButton("Close")
        close.clicked.connect(self.reject)
        close_row.addWidget(close)
        lay.addLayout(close_row)

    def _start(self):
        target = self.target.text().strip()
        if not target:
            return
        self.start_btn.setEnabled(False)
        self.target.setEnabled(False)
        self.stream.clear()
        self._runner = engine.ssh_setup_runner(target)
        self._thread = RunnerThread(self._runner.run, self)
        self._thread.line.connect(self._on_line)
        self._thread.finished_rc.connect(self._on_finished)
        self._thread.start()

    def _on_line(self, line: str):
        self.stream.appendPlainText(line)
        stripped = line.strip()
        if not stripped.endswith((":", "?")):
            return
        self._password_mode = engine.looks_like_password_prompt(stripped)
        self.entry.setEchoMode(
            QLineEdit.Password if self._password_mode else QLineEdit.Normal
        )
        self.entry.setEnabled(True)
        self.send_btn.setEnabled(True)
        self.entry.setFocus()

    def _send(self):
        if self._runner is None or not self.entry.isEnabled():
            return
        text = self.entry.text()
        if not self._password_mode:
            self.stream.appendPlainText(f"> {text}")
        # Password replies are never echoed anywhere.
        self._runner.send(text + "\n")
        self.entry.clear()
        self.entry.setEchoMode(QLineEdit.Normal)
        self.entry.setEnabled(False)
        self.send_btn.setEnabled(False)
        self._password_mode = False

    def _on_finished(self, rc: int):
        self.finished_rc = rc
        self._thread = None
        if rc == 0:
            self.hint.setText("Key access works — cron-equivalent auth verified.")
            self.hint.setStyleSheet(f"color: {GOOD}; font-weight: bold;")
        else:
            self.hint.setText(f"Failed (exit {rc}) — see the output above.")
            self.hint.setStyleSheet(f"color: {BAD}; font-weight: bold;")
        self.entry.setEnabled(False)
        self.send_btn.setEnabled(False)
        self.start_btn.setEnabled(True)
        self.target.setEnabled(True)

    def reject(self):
        if self._runner is not None and self._thread is not None:
            self._runner.send("\n")
            self._thread.wait(2000)
            if self._thread is not None and self._thread.isRunning():
                self._runner.terminate()
                self._thread.wait(2000)
        super().reject()


class CloudConnectDialog(QDialog):
    """Connect a cloud account, by driving rclone's own `config create`.

    Two shapes, because the providers genuinely differ:

      * Google Drive / OneDrive / Dropbox need an OAuth sign-in. rclone opens
        the browser ITSELF under the pty (do not open a second one here, that
        gives two tabs), and on a machine with no browser it prints a URL and
        waits for a pasted token -- which is exactly the prompt-and-forward
        shape SshSetupDialog already implements. No secret passes through this
        process at all.

      * S3 needs an access key and a secret. The secret is written to
        ~/.aws/credentials under a named profile and the remote is created with
        env_auth=true + profile=, so the key never reaches an argv where `ps`
        could read it. See engine.write_aws_profile.

    The secret field is masked and, like the ssh password path, is never
    echoed into the visible stream.
    """

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Connect a cloud account")
        self.setMinimumWidth(560)
        self._runner: engine.PtyRunner | None = None
        self._thread: RunnerThread | None = None
        self.remote_name = ""
        self.finished_rc: int | None = None

        lay = QVBoxLayout(self)

        top = QFormLayout()
        self.provider = QComboBox()
        for rtype, label in engine.CLOUD_TYPES.items():
            self.provider.addItem(label, rtype)
        self.provider.setCurrentIndex(1)  # Google Drive
        self.provider.currentIndexChanged.connect(self._provider_changed)
        self.name = QLineEdit()
        self.name.setPlaceholderText("a short name for this account, e.g. gdrive")
        top.addRow("Service:", self.provider)
        top.addRow("Account name:", self.name)
        lay.addLayout(top)

        # --- S3 page ---
        self.s3_page = QWidget()
        s3_form = QFormLayout(self.s3_page)
        s3_form.setContentsMargins(0, 0, 0, 0)
        self.s3_provider = QComboBox()
        for label, value in (("Amazon S3", "AWS"), ("Cloudflare R2", "Cloudflare"),
                             ("Backblaze B2", "Other"), ("MinIO", "Minio"),
                             ("Other S3-compatible", "Other")):
            self.s3_provider.addItem(label, value)
        self.s3_region = QLineEdit()
        self.s3_region.setPlaceholderText("e.g. eu-west-1")
        self.s3_endpoint = QLineEdit()
        self.s3_endpoint.setPlaceholderText("only for non-AWS S3-compatible storage")
        self.s3_access_key = QLineEdit()
        self.s3_access_key.setPlaceholderText("AKIA…")
        self.s3_secret = QLineEdit()
        self.s3_secret.setEchoMode(QLineEdit.Password)
        s3_form.addRow("Provider:", self.s3_provider)
        s3_form.addRow("Region:", self.s3_region)
        s3_form.addRow("Endpoint:", self.s3_endpoint)
        s3_form.addRow("Access key ID:", self.s3_access_key)
        s3_form.addRow("Secret access key:", self.s3_secret)

        # --- OAuth page ---
        self.oauth_page = QWidget()
        oauth_lay = QVBoxLayout(self.oauth_page)
        oauth_lay.setContentsMargins(0, 0, 0, 0)
        oauth_note = QLabel(
            "Your browser will open so you can sign in. Rsyncronizer never sees "
            "your password: the sign-in happens between you, the provider and "
            "rclone, which stores the result in its own config."
        )
        oauth_note.setWordWrap(True)
        oauth_note.setStyleSheet(f"color: {MUTED};")
        self.headless_box = QCheckBox("This machine has no browser — paste a token instead")
        oauth_lay.addWidget(oauth_note)
        oauth_lay.addWidget(self.headless_box)

        self.stack = QStackedWidget()
        self.stack.addWidget(self.s3_page)     # index 0
        self.stack.addWidget(self.oauth_page)  # index 1
        lay.addWidget(self.stack)

        self.connect_btn = QPushButton("Connect")
        self.connect_btn.setObjectName("primary")
        self.connect_btn.clicked.connect(self._start)
        lay.addWidget(self.connect_btn)

        self.stream = QPlainTextEdit()
        self.stream.setReadOnly(True)
        self.stream.setStyleSheet(MONO)
        self.stream.setMinimumHeight(200)
        lay.addWidget(self.stream)

        self.hint = QLabel("Credentials go into rclone's own config, never into Rsyncronizer.")
        self.hint.setWordWrap(True)
        self.hint.setStyleSheet(f"color: {MUTED};")
        lay.addWidget(self.hint)

        row = QHBoxLayout()
        self.entry = QLineEdit()
        self.entry.setPlaceholderText("rclone will ask here if it needs anything")
        self.entry.setEnabled(False)
        self.entry.returnPressed.connect(self._send)
        self.send_btn = QPushButton("Send")
        self.send_btn.setEnabled(False)
        self.send_btn.clicked.connect(self._send)
        row.addWidget(self.entry)
        row.addWidget(self.send_btn)
        lay.addLayout(row)

        self._provider_changed()

    def selected_type(self) -> str:
        return self.provider.currentData()

    def _provider_changed(self, *_):
        self.stack.setCurrentIndex(0 if self.selected_type() == "s3" else 1)

    def _start(self):
        if self._thread is not None:
            return
        name = self.name.text().strip()
        if not engine.RCLONE_NAME_RE.match(name):
            QMessageBox.warning(
                self, "Account name",
                "Use letters, digits, dots, underscores and dashes only, and start "
                "with a letter or digit. A name containing ':' or '/' would silently "
                "re-point the destination.")
            return
        rtype = self.selected_type()
        options: dict = {}
        if rtype == "s3":
            access = self.s3_access_key.text().strip()
            secret = self.s3_secret.text()
            if not access or not secret:
                QMessageBox.warning(self, "Credentials",
                                    "An access key ID and a secret access key are required.")
                return
            profile = f"rsyncronizer-{name}"
            if engine.aws_profile_exists(profile):
                if QMessageBox.question(
                        self, "Overwrite profile?",
                        f"~/.aws/credentials already has a [{profile}] profile.\n"
                        "Replace its keys?") != QMessageBox.Yes:
                    return
            try:
                path = engine.write_aws_profile(profile, access, secret,
                                                self.s3_region.text().strip())
            except OSError as exc:
                QMessageBox.critical(self, "Could not save credentials", str(exc))
                return
            # The secret is now at rest in a 0600 file and is NOT in this argv.
            self.s3_secret.clear()
            options = {
                "provider": self.s3_provider.currentData(),
                "env_auth": "true",
                "profile": profile,
                "shared_credentials_file": path,
            }
            if self.s3_region.text().strip():
                options["region"] = self.s3_region.text().strip()
            if self.s3_endpoint.text().strip():
                options["endpoint"] = self.s3_endpoint.text().strip()
            self.stream.appendPlainText(
                f"Saved the secret key to {path} as [{profile}] (mode 0600).\n"
                "It is not passed on any command line.")
        elif self.headless_box.isChecked():
            # rclone's paste-a-token flow, for a machine with no browser.
            options = {"config_is_local": "false"}

        self.remote_name = name
        self.connect_btn.setEnabled(False)
        self.provider.setEnabled(False)
        self.name.setEnabled(False)
        self.stream.appendPlainText(f"$ rclone config create {name} {rtype} …")
        self._runner = engine.cloud_config_runner(name, rtype, options)
        self._thread = RunnerThread(lambda on_line: self._runner.run(on_line=on_line), self)
        self._thread.line.connect(self._on_line)
        self._thread.finished_rc.connect(self._on_finished)
        self._thread.start()

    def _on_line(self, text: str):
        self.stream.appendPlainText(text)
        stripped = text.strip()
        if not (stripped.endswith(":") or stripped.endswith("?")):
            return
        self.entry.setEnabled(True)
        self.send_btn.setEnabled(True)
        self.entry.setFocus()

    def _send(self):
        if self._runner is None or not self.entry.isEnabled():
            return
        text = self.entry.text()
        self.stream.appendPlainText(f"> {text}")
        self._runner.send(text + "\n")
        self.entry.clear()
        self.entry.setEnabled(False)
        self.send_btn.setEnabled(False)

    def _on_finished(self, rc: int):
        self.finished_rc = rc
        self._thread = None
        self.entry.setEnabled(False)
        self.send_btn.setEnabled(False)
        if rc == 0:
            self.hint.setText(f"Connected. '{self.remote_name}' is ready to use.")
            self.hint.setStyleSheet(f"color: {GOOD}; font-weight: bold;")
            self.accept()
            return
        self.hint.setText(f"Failed (exit {rc}) — see the output above.")
        self.hint.setStyleSheet(f"color: {BAD}; font-weight: bold;")
        self.connect_btn.setEnabled(True)
        self.provider.setEnabled(True)
        self.name.setEnabled(True)

    def reject(self):
        if self._runner is not None and self._thread is not None:
            self._runner.send("\n")
            self._thread.wait(2000)
            if self._thread is not None and self._thread.isRunning():
                self._runner.terminate()
                self._thread.wait(2000)
        super().reject()


class ManageRemotesDialog(QDialog):
    """Remote Control management: the list of connected servers with removal,
    plus the add-a-server form (test connection, SSH key setup)."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Manage Remote Control")
        self.setMinimumWidth(600)
        self.changed = False
        self._thread: RunnerThread | None = None

        lay = QVBoxLayout(self)

        # --- existing connections ----------------------------------------
        connected = QLabel("Connected servers")
        connected.setStyleSheet("font-weight: bold;")
        lay.addWidget(connected)
        self._list_holder = QVBoxLayout()
        lay.addLayout(self._list_holder)
        self._rebuild_list()

        sep = QLabel("Add a server")
        sep.setStyleSheet("font-weight: bold; margin-top: 10px;")
        lay.addWidget(sep)

        self.label = QLineEdit()
        self.label.setPlaceholderText("label, e.g. workstation")
        self.host = QLineEdit()
        self.host.setPlaceholderText("ssh host or user@host, e.g. alice@backup-server")
        self.path = QLineEdit("~/rsyncronizer")
        for caption, widget in (("Name shown in the app:", self.label),
                                ("SSH host:", self.host),
                                ("Engine path on that machine:", self.path)):
            lay.addWidget(QLabel(caption))
            lay.addWidget(widget)

        self.stream = QPlainTextEdit()
        self.stream.setReadOnly(True)
        self.stream.setStyleSheet(MONO)
        self.stream.setMinimumHeight(140)
        lay.addWidget(self.stream)
        self.hint = QLabel("")
        self.hint.setStyleSheet(f"color: {MUTED};")
        lay.addWidget(self.hint)

        buttons = QHBoxLayout()
        self.keys_btn = QPushButton("Set up SSH key…")
        self.keys_btn.clicked.connect(self._keys)
        self.test_btn = QPushButton("Save + test connection")
        self.test_btn.setObjectName("primary")
        self.test_btn.clicked.connect(self._save_and_test)
        close = QPushButton("Close")
        close.clicked.connect(self.reject)
        buttons.addWidget(self.keys_btn)
        buttons.addStretch(1)
        buttons.addWidget(self.test_btn)
        buttons.addWidget(close)
        lay.addLayout(buttons)

    def _rebuild_list(self):
        while self._list_holder.count():
            item = self._list_holder.takeAt(0)
            w = item.widget()
            if w is not None:
                w.deleteLater()
        remotes = engine.list_remotes()
        if not remotes:
            none = QLabel("No servers connected yet.")
            none.setStyleSheet(f"color: {MUTED};")
            self._list_holder.addWidget(none)
            return
        for remote in remotes:
            row_widget = QWidget()
            row = QHBoxLayout(row_widget)
            row.setContentsMargins(0, 0, 0, 0)
            text = QLabel(f"REMOTE: {remote['label']}   {remote['host']}   {remote['path']}")
            text.setStyleSheet(MONO)
            remove = QPushButton("Remove")
            remove.setObjectName("danger")
            remove.clicked.connect(
                lambda _=False, l=remote["label"]: self._remove(l))
            row.addWidget(text)
            row.addStretch(1)
            row.addWidget(remove)
            self._list_holder.addWidget(row_widget)

    def _remove(self, label: str):
        if confirm_remove_remote(label, self):
            engine.remove_remote(label)
            self.changed = True
            self._rebuild_list()

    def _keys(self):
        dlg = SshSetupDialog(self.host.text().strip(), self.window())
        dlg.exec()

    def _save_and_test(self):
        if self._thread is not None:
            return
        label = self.label.text().strip()
        host = self.host.text().strip()
        path = self.path.text().strip()
        rc, msg = engine.add_remote(label, host, path)
        self.stream.appendPlainText(msg)
        if rc != 0:
            self.hint.setText("Not saved — fix the fields above.")
            self.hint.setStyleSheet(f"color: {BAD};")
            return
        self.changed = True
        self._rebuild_list()
        self.hint.setText("Saved. Testing the connection…")
        self.hint.setStyleSheet(f"color: {MUTED};")
        self.test_btn.setEnabled(False)
        runner = engine.PtyRunner(engine._remote_argv(label, "status"),
                                  cwd=engine.engine_root())
        self._thread = RunnerThread(runner.run, self)
        self._thread.line.connect(self.stream.appendPlainText)
        self._thread.finished_rc.connect(self._tested)
        self._thread.start()

    def _tested(self, rc: int):
        self._thread = None
        self.test_btn.setEnabled(True)
        if rc == 0:
            self.hint.setText("Connection works — the server's backups will appear in the app.")
            self.hint.setStyleSheet(f"color: {GOOD}; font-weight: bold;")
        elif rc == 69:
            self.hint.setText("Unreachable or key auth broken — try “Set up SSH key…”.")
            self.hint.setStyleSheet(f"color: {WARN}; font-weight: bold;")
        else:
            self.hint.setText(f"Test failed (exit {rc}) — see the output above.")
            self.hint.setStyleSheet(f"color: {BAD}; font-weight: bold;")


class IgnoreDialog(QDialog):
    """View/edit the exclude files. The global file is THE complete global
    list (seeded from the shipped defaults, then entirely the user's — no
    hidden layer behind it); per-backup exclude.txt files stack on top."""

    GLOBAL = "Global (the complete list, applies to every backup)"

    PER_BACKUP_TEMPLATE = (
        "# Extra excludes for THIS backup only, on top of the global list.\n"
        "# One rule per line, '- ' prefix, bare basenames.\n"
    )

    def __init__(self, backups: list[str], preselect: str | None = None, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Ignore rules")
        self.setMinimumSize(600, 480)
        root = engine.engine_root()
        # Seeded on demand: the Global entry always opens the full visible list.
        self._paths = {self.GLOBAL: engine.ensure_global_exclude(root)}
        for name in backups:
            self._paths[f"Backup: {name}"] = os.path.join(root, "config", name, "exclude.txt")

        lay = QVBoxLayout(self)
        self.picker = QComboBox()
        self.picker.addItems(list(self._paths.keys()))
        lay.addWidget(self.picker)
        self.editor = QPlainTextEdit()
        self.editor.setStyleSheet(MONO)
        lay.addWidget(self.editor)
        self.hint = QLabel("")
        self.hint.setStyleSheet(f"color: {MUTED};")
        lay.addWidget(self.hint)
        buttons = QHBoxLayout()
        buttons.addStretch(1)
        self.save_btn = QPushButton("Save")
        self.save_btn.setObjectName("primary")
        self.save_btn.clicked.connect(self._save)
        close = QPushButton("Close")
        close.clicked.connect(self.reject)
        buttons.addWidget(self.save_btn)
        buttons.addWidget(close)
        lay.addLayout(buttons)

        self.picker.currentTextChanged.connect(self._load)
        if preselect and f"Backup: {preselect}" in self._paths:
            self.picker.setCurrentText(f"Backup: {preselect}")
        self._load(self.picker.currentText())

    def _load(self, key: str):
        path = self._paths[key]
        text = ""
        if os.path.isfile(path):
            with open(path, "r", encoding="utf-8") as fh:
                text = fh.read()
        elif key.startswith("Backup: "):
            text = self.PER_BACKUP_TEMPLATE
        self.editor.setPlainText(text)
        self.editor.setReadOnly(False)
        self.save_btn.setEnabled(True)
        self.hint.setText(path)

    def _save(self):
        key = self.picker.currentText()
        path = self._paths[key]
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(self.editor.toPlainText())
        self.hint.setText(f"Saved {path}")
        self.hint.setStyleSheet(f"color: {GOOD};")


class UpdateDialog(QDialog):
    """Download the release asset, swap the install, relaunch."""

    def __init__(self, info: dict, current_version: str, parent=None):
        super().__init__(parent)
        from . import updater

        self._updater = updater
        self._info = info
        self.setWindowTitle("Update Rsyncronizer")
        self.setMinimumWidth(480)
        lay = QVBoxLayout(self)
        lay.addWidget(QLabel(
            f"<b>{info['version']}</b> is available (you have {current_version})."))
        self.state = QLabel("The app will download the update, replace itself "
                            "and restart. Backups and settings are untouched.")
        self.state.setWordWrap(True)
        self.state.setStyleSheet(f"color: {MUTED};")
        lay.addWidget(self.state)
        from PySide6.QtWidgets import QProgressBar

        self.bar = QProgressBar()
        self.bar.setRange(0, 100)
        self.bar.setValue(0)
        lay.addWidget(self.bar)
        row = QHBoxLayout()
        row.addStretch(1)
        self.go = QPushButton(f"Update to {info['version']}")
        self.go.setObjectName("primary")
        self.go.clicked.connect(self._start)
        cancel = QPushButton("Later")
        cancel.clicked.connect(self.reject)
        row.addWidget(self.go)
        row.addWidget(cancel)
        lay.addLayout(row)
        self._thread: RunnerThread | None = None

    def _start(self):
        import tempfile

        self.go.setEnabled(False)
        target = self._updater.install_target()
        if target is None:
            self.state.setText("Running from source — update with git instead.")
            self.state.setStyleSheet(f"color: {WARN};")
            return
        info, updater = self._info, self._updater

        def work(on_line=None):
            try:
                tmp = tempfile.mkdtemp(prefix="rsyncronizer-dl-")
                on_line("downloading")
                path = updater.download(
                    info["asset_url"], tmp,
                    on_progress=lambda s, t: on_line(f"pct:{int(s * 100 / t)}" if t else "pct:0"))
                on_line("applying")
                updater.apply_update(path, target)
                on_line("done")
                return 0
            except Exception as exc:   # surfaced in the dialog, never a crash
                on_line(f"error:{exc}")
                return 1

        self._thread = RunnerThread(work, self)
        self._thread.line.connect(self._progress)
        self._thread.finished_rc.connect(self._finished)
        self._thread.start()

    def _progress(self, msg: str):
        if msg.startswith("pct:"):
            self.bar.setValue(int(msg[4:]))
        elif msg == "downloading":
            self.state.setText("Downloading…")
        elif msg == "applying":
            self.bar.setRange(0, 0)
            self.state.setText("Installing…")
        elif msg.startswith("error:"):
            self.bar.setRange(0, 100)
            self.state.setText(f"Update failed: {msg[6:]} — the current version "
                               "is untouched.")
            self.state.setStyleSheet(f"color: {BAD};")

    def _finished(self, rc: int):
        self._thread = None
        if rc == 0:
            self.state.setText("Updated — restarting.")
            self.state.setStyleSheet(f"color: {GOOD}; font-weight: bold;")
            from PySide6.QtWidgets import QApplication

            self._updater.relaunch(self._updater.install_target())
            QApplication.instance().quit()
        else:
            self.go.setEnabled(True)


def confirm_remove_remote(label: str, parent) -> bool:
    box = QMessageBox(parent)
    box.setWindowTitle("Remove server")
    box.setText(f"Remove the server “{label}” from this app?")
    box.setInformativeText("Only the local definition is removed — nothing on the server changes.")
    remove = box.addButton("Remove", QMessageBox.DestructiveRole)
    box.addButton("Cancel", QMessageBox.RejectRole)
    box.exec()
    return box.clickedButton() is remove


def open_support_page() -> None:
    """Module-level so tests can monkeypatch it away from a real browser."""
    from PySide6.QtCore import QUrl
    from PySide6.QtGui import QDesktopServices

    QDesktopServices.openUrl(QUrl(engine.SUPPORT_URL))


SUPPORT_PHRASE = "i have supported"


class SupportDialog(QDialog):
    """The once-every-10-completed-runs reminder.

    Honor system by design (Buy Me a Coffee cannot verify donations):
    "Buy me a coffee" opens the page WITHOUT closing the dialog, since opening
    it proves nothing; typing the phrase 'i have supported' silences the
    reminder forever; "Later" — and Esc, and the window close button — defers
    it by another 10 completed runs."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Support Rsyncronizer")
        self.setMinimumWidth(480)
        self.choice: str | None = None
        self._resolved = False
        count = engine.support_state()["run_count"]
        lay = QVBoxLayout(self)
        lay.addWidget(QLabel(
            f"<b>Rsyncronizer has completed {count} backups on this machine.</b>"))
        body = QLabel(
            "It is completely free and will be so forever. If you find it "
            "useful, please consider supporting me and my work.")
        body.setWordWrap(True)
        lay.addWidget(body)
        note = QLabel(
            "If you have already supported me, or simply do not want to, type "
            "“i have supported” below and this reminder will never be shown "
            "again. Want to decide later? Click Later and it will pop up "
            "after 10 more backups.")
        note.setWordWrap(True)
        note.setStyleSheet(f"color: {MUTED};")
        lay.addWidget(note)
        self.phrase = QLineEdit()
        self.phrase.setPlaceholderText(SUPPORT_PHRASE)
        self.phrase.textChanged.connect(self._check_phrase)
        lay.addWidget(self.phrase)
        row = QHBoxLayout()
        row.addStretch(1)
        self.buy_btn = QPushButton("Buy me a coffee")
        self.buy_btn.setObjectName("primary")
        # Lambda so tests monkeypatching the module attribute take effect.
        self.buy_btn.clicked.connect(lambda: open_support_page())
        self.later_btn = QPushButton("Later")
        self.later_btn.setDefault(True)
        self.later_btn.clicked.connect(self.reject)
        row.addWidget(self.buy_btn)
        row.addWidget(self.later_btn)
        lay.addLayout(row)

    def _check_phrase(self, text: str):
        if text.strip().lower() == SUPPORT_PHRASE:
            self._resolved = True
            self.choice = "supported"
            engine.mark_supported()
            self.accept()

    def reject(self):
        # Esc and the close button land here too; defer exactly once.
        if not self._resolved:
            self._resolved = True
            self.choice = "later"
            engine.defer_support()
        super().reject()
