"""Widget smoke tests, offscreen. These prove the Qt layer constructs and
that the wizard's form state feeds build_answers correctly — the heavy
behaviour all lives in the engine layer and the bash suite."""

import pytest

pyside = pytest.importorskip("PySide6")

from PySide6.QtWidgets import QApplication  # noqa: E402

from app import engine  # noqa: E402
from app.wizard import BackupWizard  # noqa: E402


@pytest.fixture(scope="module")
def qapp():
    app = QApplication.instance() or QApplication([])
    yield app


def test_wizard_form_to_answers_ssh(qapp, engine_home):
    wiz = BackupWizard()
    wiz.basics.name.setText("docs-to-box")
    wiz.basics.source.setText("/tmp/src")
    wiz.dest.ssh_radio.setChecked(True)
    wiz.dest.host.setText("box")
    wiz.dest.user.setText("")
    wiz.dest.ssh_dest.setText("/backup")
    wiz.sched.schedule_on.setChecked(True)
    wiz.sched.preset.setCurrentIndex(0)

    answers = engine.build_answers(wiz.form_state())
    assert answers["A_NAME"] == "docs-to-box"
    assert answers["A_DEST_KIND"] == "1"
    assert answers["A_USER"] == "@none"
    assert answers["A_SCHEDULE_CHOICE"] == "1"
    assert answers["A_CRON_CONFIRM"] == "y"
    wiz.deleteLater()


def test_wizard_pages_complete_gating(qapp, engine_home):
    wiz = BackupWizard()
    assert not wiz.basics.isComplete()
    wiz.basics.name.setText("bad name!")
    wiz.basics.source.setText("/tmp/x")
    assert not wiz.basics.isComplete()   # the name charset gate
    wiz.basics.name.setText("good-name")
    assert wiz.basics.isComplete()
    wiz.deleteLater()


def test_status_view_constructs_empty(qapp, engine_home):
    from PySide6.QtWidgets import QPlainTextEdit
    from app.status_view import StatusView

    log = QPlainTextEdit()
    view = StatusView(log)     # materializes an empty engine; no backups
    assert view is not None
    view.deleteLater()
    log.deleteLater()


def _banner_texts(view):
    from PySide6.QtWidgets import QLabel
    return [w.text() for w in view.findChildren(QLabel) if w.text().startswith("!!")]


def _status_with(monkeypatch, backups):
    from app import engine as eng
    monkeypatch.setattr(eng, "status", lambda: (0, {}, backups))
    monkeypatch.setattr(eng, "list_remotes", lambda: [])
    monkeypatch.setattr(eng, "rclone_install_hint", lambda: "brew install rclone")


CLOUD_ROW = {"BACKUP": "docs-to-drive", "DEST_TYPE": "cloud",
             "DEST": "gdrive:Backups/laptop", "RCLONE_REMOTE": "gdrive",
             "CLOUD_PROVIDER": "drive", "REMOTE_DEFINED": "1",
             "NEVER_RAN": "1", "SCHEDULE": "0 2 * * *", "TRIGGER": "0"}


def test_status_view_banner_when_rclone_missing_and_cloud_configured(qapp, engine_home, monkeypatch):
    from PySide6.QtWidgets import QPlainTextEdit
    from app import engine as eng
    from app.status_view import StatusView

    _status_with(monkeypatch, [dict(CLOUD_ROW)])
    monkeypatch.setattr(eng, "rclone_path", lambda: None)
    log = QPlainTextEdit()
    view = StatusView(log)
    assert any("rclone is not installed" in t for t in _banner_texts(view))
    view.deleteLater()
    log.deleteLater()


def test_status_view_has_no_rclone_banner_without_a_cloud_backup(qapp, engine_home, monkeypatch):
    # rclone is optional: its absence must be silent for an rsync-only machine.
    from PySide6.QtWidgets import QPlainTextEdit
    from app import engine as eng
    from app.status_view import StatusView

    _status_with(monkeypatch, [{"BACKUP": "docs", "DEST_TYPE": "ssh",
                                "DEST": "box:/backup", "NEVER_RAN": "1",
                                "SCHEDULE": "0 2 * * *", "TRIGGER": "0"}])
    monkeypatch.setattr(eng, "rclone_path", lambda: None)
    log = QPlainTextEdit()
    view = StatusView(log)
    assert not any("rclone" in t for t in _banner_texts(view))
    view.deleteLater()
    log.deleteLater()
