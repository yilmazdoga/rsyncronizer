"""Remote plumbing (against tests/fake-ssh) and the secondary dialogs."""

import os

import pytest

pytest.importorskip("PySide6")

from PySide6.QtWidgets import QApplication, QLineEdit  # noqa: E402

from app import engine  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FAKE_SSH = os.path.join(REPO, "tests", "fake-ssh")


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


@pytest.fixture
def fake_ssh(engine_home, monkeypatch, tmp_path):
    monkeypatch.setenv("RBS_SSH_BIN", FAKE_SSH)
    monkeypatch.setenv("FAKE_SSH_ARGV", str(tmp_path / "ssh-argv.txt"))
    return FAKE_SSH


# --------------------------------------------------------------------------
# Remote engine plumbing
# --------------------------------------------------------------------------

def test_remote_add_list_status_remove(fake_ssh):
    rc, msg = engine.add_remote("box", "fakebox", "~/rsyncronizer")
    assert rc == 0, msg
    remotes = engine.list_remotes()
    assert remotes == [{"label": "box", "host": "fakebox",
                        "path": "~/rsyncronizer"}]

    rc, header, backups, error = engine.remote_status("box")
    assert rc == 0 and not error
    assert header.get("REMOTE_VERSION") == "0.1.0"
    assert [b["BACKUP"] for b in backups] == ["remote-backup"]
    assert backups[0]["VERDICT"] == "SUCCESS"

    rc, _ = engine.remove_remote("box")
    assert rc == 0
    assert engine.list_remotes() == []


def test_remote_add_rejects_bad_host(fake_ssh):
    rc, msg = engine.add_remote("evil", "-oProxyCommand=boom", "~/x")
    assert rc == 78
    assert "invalid host" in msg


def test_remote_status_unreachable(fake_ssh, monkeypatch):
    engine.add_remote("box", "fakebox", "~/x")
    monkeypatch.setenv("FAKE_SSH_EXIT", "255")
    rc, _, backups, error = engine.remote_status("box")
    assert rc == 69 and not backups
    assert "ssh-setup" in error
    monkeypatch.delenv("FAKE_SSH_EXIT")
    engine.remove_remote("box")


def test_remote_runner_argv_shape(fake_ssh):
    engine.add_remote("box", "fakebox", "~/x")
    runner = engine.remote_runner("box", "sync-deletions", "docs")
    joined = " ".join(runner._argv)
    assert "remote.sh" in joined and "box sync-deletions docs" in joined
    engine.remove_remote("box")


# --------------------------------------------------------------------------
# SSH dialog: password masking and no-echo
# --------------------------------------------------------------------------

class _StubRunner:
    def __init__(self):
        self.sent = []

    def send(self, text):
        self.sent.append(text)


def test_ssh_dialog_masks_password_and_never_echoes(qapp, engine_home):
    from app.dialogs import SshSetupDialog

    dlg = SshSetupDialog("user@fakebox")
    dlg._runner = _StubRunner()

    dlg._on_line("user@fakebox's password: ")
    assert dlg._password_mode
    assert dlg.entry.echoMode() == QLineEdit.Password
    dlg.entry.setText("hunter2")
    dlg._send()
    assert dlg._runner.sent == ["hunter2\n"]
    assert "hunter2" not in dlg.stream.toPlainText()
    assert dlg.entry.text() == ""

    # A non-password prompt (host key) is visible and echoed.
    dlg._on_line("Are you sure you want to continue connecting (yes/no/[fingerprint])? ")
    assert not dlg._password_mode
    assert dlg.entry.echoMode() == QLineEdit.Normal
    dlg.entry.setText("yes")
    dlg._send()
    assert dlg._runner.sent[-1] == "yes\n"
    assert "> yes" in dlg.stream.toPlainText()
    dlg.deleteLater()


def test_remote_title_shows_machine_name():
    # Registered by its name: just the name.
    assert engine.remote_title("backup-server", "backup-server") == "REMOTE: backup-server"
    # Registered by IP: the deduced hostname, IP in parentheses.
    assert engine.remote_title("192.168.1.50", "backup-server") \
        == "REMOTE: backup-server  (192.168.1.50)"
    # user@ prefix and domain suffix are stripped for display.
    assert engine.remote_title("user@192.168.1.50", "backup-server.lan") \
        == "REMOTE: backup-server  (192.168.1.50)"
    # Before the fetch lands there is only the registration.
    assert engine.remote_title("user@backup-server") == "REMOTE: backup-server"


# --------------------------------------------------------------------------
# Manage Remote Control panel
# --------------------------------------------------------------------------

def test_manage_remotes_lists_and_removes(qapp, fake_ssh, monkeypatch):
    from app import dialogs as dlgmod

    engine.add_remote("box", "fakebox", "~/x")
    dlg = dlgmod.ManageRemotesDialog()
    labels = [w.text() for w in dlg.findChildren(type(dlg.hint))
              if w.text().startswith("REMOTE: ")]
    assert any("REMOTE: box" in t for t in labels)

    # Removal goes through the confirm dialog; force a yes.
    monkeypatch.setattr(dlgmod, "confirm_remove_remote", lambda label, parent: True)
    dlg._remove("box")
    assert dlg.changed
    assert engine.list_remotes() == []
    dlg.deleteLater()


# --------------------------------------------------------------------------
# Ignore dialog round trip
# --------------------------------------------------------------------------

def test_ignore_dialog_global_is_seeded_and_editable(qapp, engine_home):
    from app.dialogs import IgnoreDialog

    engine.materialize()
    dlg = IgnoreDialog(backups=["docs"])
    dlg.picker.setCurrentText(IgnoreDialog.GLOBAL)
    # No hidden excludes: the Global entry opens the COMPLETE list, seeded
    # from the shipped defaults and fully editable.
    text = dlg.editor.toPlainText()
    for rule in ("- .DS_Store", "- ._*", "- @eaDir", "- __pycache__", "- .venv"):
        assert rule in text, rule
    assert not dlg.editor.isReadOnly()
    # There is no read-only baseline entry any more.
    entries = [dlg.picker.itemText(i) for i in range(dlg.picker.count())]
    assert not any("baseline" in e.lower() for e in entries)

    # Deleting everything and saving really means "no global excludes".
    dlg.editor.setPlainText("- only_this\n")
    dlg._save()
    path = os.path.join(engine.engine_root(), "config", "global-exclude.txt")
    assert open(path).read() == "- only_this\n"

    # Per-backup file gets the template and saves next to the config.
    dlg.picker.setCurrentText("Backup: docs")
    assert "THIS backup only" in dlg.editor.toPlainText()
    dlg.editor.setPlainText("- node_modules\n")
    dlg._save()
    per = os.path.join(engine.engine_root(), "config", "docs", "exclude.txt")
    assert open(per).read() == "- node_modules\n"
    dlg.deleteLater()


def test_global_exclude_seeding_never_overwrites(engine_home):
    engine.materialize()
    path = os.path.join(engine.engine_root(), "config", "global-exclude.txt")
    assert "- .DS_Store" in open(path).read()      # seeded on first materialize
    open(path, "w").write("- my_only_rule\n")
    engine.materialize()                            # refresh must keep user edits
    engine.ensure_global_exclude()
    assert open(path).read() == "- my_only_rule\n"
