"""RunDialog phases, cards, PtyRunner, classifiers — offscreen."""

import queue
import time

import pytest

pytest.importorskip("PySide6")

from PySide6.QtWidgets import QApplication  # noqa: E402

from app import engine  # noqa: E402
from app.run_panel import is_file_line  # noqa: E402
from app.status_view import BackupCard, RunDialog  # noqa: E402


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def pump(app, done, timeout=30):
    deadline = time.time() + timeout
    while not done() and time.time() < deadline:
        app.processEvents()
        time.sleep(0.02)
    return done()


BLOCK = {
    "BACKUP": "docs", "SRC": "/home/me/docs", "DEST": "box:/backup",
    "DEST_TYPE": "ssh", "SCHEDULE": "0 2 * * *", "TRIGGER": "0",
    "RUNNER_MISSING": "0", "NEVER_RAN": "0", "LAST_WHEN": "2026-08-10 02:00:00",
    "LAST_EPOCH": "1786400000", "RC": "0", "VERDICT": "SUCCESS", "FILES": "12",
    "TOTAL_FILES": "300", "ELAPSED": "30", "DRY": "0", "TRIGGERED": "cron",
    "STALE": "0", "WAITING": "0", "BOOTSTRAP_ALERT": "0", "LOG": "/dev/null",
}


class _FakeView:
    def __init__(self):
        self.calls = []

    def start_run(self, name, dry, remote=None, total_hint=""):
        self.calls.append((name, dry, remote))

    def refresh(self):
        self.calls.append(("refresh",))

    def open_ignores(self, name=None):
        self.calls.append(("ignores", name))

    def modal_guard(self, entering):
        pass

    def window(self):
        return None


class FakeSyncRunner:
    """Scripted engine conversation for the staged dialog."""

    def __init__(self):
        self._q = queue.Queue()
        self.sent = []

    def send(self, text):
        self.sent.append(text)
        self._q.put(text)

    def terminate(self):
        self._q.put("\n")

    def run(self, on_line=None):
        on_line("backup   : docs")
        on_line("prune    : scanning the destination for entries absent from the source...")
        on_line("  will delete: extra.txt")
        on_line("  will delete: stale dir/")
        on_line(engine.SYNC_DELETIONS_PROMPT
                + " 2 entries from the destination (anything else aborts): ")
        reply = self._q.get(timeout=30).strip()
        if reply in ("I confirm", "i confirm"):
            on_line("prune    : " + engine.SYNC_DELETIONS_CONFIRMED + " for this run")
            on_line("RESULT: SUCCESS (0)")
            return 0
        on_line("RESULT: NOT CONFIRMED -- nothing was transferred or deleted.")
        return 75


# --------------------------------------------------------------------------
# Cards
# --------------------------------------------------------------------------

def test_card_collapsed_then_expands(qapp):
    card = BackupCard(dict(BLOCK), _FakeView())
    assert card.details.isHidden()
    card.toggle()
    assert not card.details.isHidden()
    card.toggle()
    assert card.details.isHidden()
    card.deleteLater()


def test_card_local_has_delete_and_ignores(qapp):
    card = BackupCard(dict(BLOCK), _FakeView())
    assert card.del_btn.text() == "Delete backup schedule"
    assert card.del_btn.objectName() == "danger"
    assert not card.ignore_btn.isHidden()
    card.deleteLater()


def test_card_remote_hides_local_only_actions(qapp):
    card = BackupCard(dict(BLOCK), _FakeView(), remote_label="workstation")
    assert card.del_btn.isHidden()
    assert card.ignore_btn.isHidden()
    assert not card.run_btn.isHidden()
    card.deleteLater()


# --------------------------------------------------------------------------
# RunDialog phases
# --------------------------------------------------------------------------

def test_run_dialog_direct_choices(qapp):
    dlg = RunDialog("docs")
    dlg._direct("dry")
    assert dlg.choice == "dry"
    dlg.deleteLater()


def test_run_dialog_staged_confirm_flow(qapp):
    fake = FakeSyncRunner()
    dlg = RunDialog("docs", runner_factory=lambda: fake)
    dlg._start_sync_deletions()
    assert pump(qapp, lambda: dlg._entry.isEnabled())
    # Scan phase produced the parsed list, not raw noise.
    items = [dlg._list.item(i).text() for i in range(dlg._list.count())]
    assert items == ["extra.txt", "stale dir/"]
    assert "2 entries" in dlg._count.text()
    dlg._entry.setText("I confirm")
    dlg._send_reply()
    assert pump(qapp, lambda: dlg._finished_rc is not None)
    assert dlg._finished_rc == 0
    assert fake.sent == ["I confirm\n"]
    assert "Finished" in dlg._phase.text()
    dlg.deleteLater()


def test_run_dialog_staged_decline_flow(qapp):
    fake = FakeSyncRunner()
    dlg = RunDialog("docs", runner_factory=lambda: fake)
    dlg._start_sync_deletions()
    assert pump(qapp, lambda: dlg._entry.isEnabled())
    dlg._entry.setText("nope")
    dlg._send_reply()
    assert pump(qapp, lambda: dlg._finished_rc is not None)
    assert dlg._finished_rc == 75
    assert "Aborted" in dlg._phase.text()
    dlg.deleteLater()


# --------------------------------------------------------------------------
# Classifiers and helpers
# --------------------------------------------------------------------------

def test_is_file_line_classifier():
    assert is_file_line("Documents/paper/draft.tex")
    assert is_file_line("src-new/sub/b.txt")
    assert not is_file_line("")
    assert not is_file_line("sending incremental file list")
    assert not is_file_line("sent 161 bytes  received 44 bytes  186363 bytes/sec")
    assert not is_file_line("total size is 11  speedup is 0.05")
    assert not is_file_line("Number of files: 4")
    assert not is_file_line("backup   : documents-to-ssd")
    assert not is_file_line("RESULT: SUCCESS (0)")


def test_looks_like_password_prompt():
    assert engine.looks_like_password_prompt("user@backup-server's password: ")
    assert engine.looks_like_password_prompt("Enter passphrase for key: ")
    assert not engine.looks_like_password_prompt(
        "Type 'I confirm' to delete these 2 entries (anything else aborts): ")
    assert not engine.looks_like_password_prompt("Are you sure you want to continue connecting (yes/no)? ")


def test_humanize_schedule():
    assert engine.humanize_schedule(
        {"SCHEDULE": "0 2 * * *", "DEST_TYPE": "ssh"}) == "every day at 02:00"
    assert engine.humanize_schedule(
        {"SCHEDULE": "*/15 * * * *", "DEST_TYPE": "local"}
    ) == "on drive connect (checked every 15 min)"
    assert engine.humanize_schedule(
        {"SCHEDULE": "*/15 * * * *", "DEST_TYPE": "ssh"}) == "every 15 min"
    assert engine.humanize_schedule(
        {"SCHEDULE": "30 12,20 * * *", "DEST_TYPE": "ssh"}) == "daily at 12:30, 20:30"
    assert engine.humanize_schedule(
        {"SCHEDULE": "0 3 * * 0", "DEST_TYPE": "ssh"}) == "every Sunday at 03:00"
    assert engine.humanize_schedule(
        {"SCHEDULE": "", "TRIGGER": "1", "DEST_TYPE": "local"}) == "on drive connect"
    assert engine.humanize_schedule(
        {"SCHEDULE": "", "DEST_TYPE": "ssh"}) == "manual runs only"


# --------------------------------------------------------------------------
# PtyRunner
# --------------------------------------------------------------------------

def test_pty_runner_send_roundtrip(tmp_path):
    script = tmp_path / "echoer.sh"
    script.write_text(
        "#!/bin/bash\n"
        "printf \"Type 'I confirm' to delete these 2 entries (anything else aborts): \"\n"
        "IFS= read -r reply\n"
        "echo \"reply:$reply\"\n"
        "[ \"$reply\" = 'I confirm' ] && exit 0 || exit 75\n"
    )
    script.chmod(0o755)
    runner = engine.PtyRunner(["/bin/bash", str(script)])
    lines = []
    seen_prompt = []

    def on_line(text):
        lines.append(text)
        if engine.SYNC_DELETIONS_PROMPT in text and not seen_prompt:
            seen_prompt.append(True)
            runner.send("I confirm\n")

    rc = runner.run(on_line=on_line)
    assert seen_prompt, f"prompt never flushed; lines={lines}"
    assert rc == 0
    assert any("reply:I confirm" in ln for ln in lines)


def test_pty_runner_child_owns_dev_tty(tmp_path):
    """ssh reads passwords from /dev/tty; the pty must be the child's
    CONTROLLING terminal or those prompts never reach the app."""
    script = tmp_path / "ctty.sh"
    script.write_text(
        "#!/bin/bash\n"
        "printf 'password: ' > /dev/tty\n"
        "IFS= read -r secret < /dev/tty || exit 9\n"
        "echo \"got:$secret\"\n"
        "exit 0\n"
    )
    script.chmod(0o755)
    runner = engine.PtyRunner(["/bin/bash", str(script)])
    lines = []

    def on_line(text):
        lines.append(text)
        if text.endswith("password: "):
            runner.send("s3cret\n")

    rc = runner.run(on_line=on_line)
    assert rc == 0, lines
    assert any("got:s3cret" in ln for ln in lines)


def test_pty_runner_decline(tmp_path):
    script = tmp_path / "echoer.sh"
    script.write_text(
        "#!/bin/bash\n"
        "printf \"Type 'I confirm' to delete these 2 entries (anything else aborts): \"\n"
        "IFS= read -r reply\n"
        "[ \"$reply\" = 'I confirm' ] && exit 0 || exit 75\n"
    )
    script.chmod(0o755)
    runner = engine.PtyRunner(["/bin/bash", str(script)])

    def on_line(text):
        if engine.SYNC_DELETIONS_PROMPT in text:
            runner.send("nope\n")

    assert runner.run(on_line=on_line) == 75


# --------------------------------------------------------------------------
# The staged dialog is transport-neutral
# --------------------------------------------------------------------------

class FakeCloudSyncRunner(FakeSyncRunner):
    """The same conversation in rclone's wording.

    The mechanism line that follows the marker must NOT be classified -- that
    is the whole reason the marker moved off it.
    """

    def run(self, on_line=None):
        on_line("backup   : docs")
        on_line("prune    : scanning the destination for entries absent from the source...")
        on_line("  will delete: extra.txt")
        on_line("  will delete: stale dir/gone.txt")
        on_line(engine.SYNC_DELETIONS_PROMPT
                + " 2 entries from the destination (anything else aborts): ")
        reply = self._q.get(timeout=30).strip()
        if reply in ("I confirm", "i confirm"):
            on_line("prune    : " + engine.SYNC_DELETIONS_CONFIRMED)
            on_line("prune    : rclone sync --delete-after --max-delete=2 enabled for this run")
            on_line("RESULT: SUCCESS (0)")
            return 0
        on_line("RESULT: NOT CONFIRMED -- nothing was transferred or deleted.")
        return 75


class LegacyEngineRunner(FakeSyncRunner):
    """A REMOTE machine still on 0.2.x, which this app cannot update."""

    def run(self, on_line=None):
        on_line(engine.SYNC_DELETIONS_PROMPT + " 1 entries: ")
        self._q.get(timeout=30)
        on_line("prune    : " + engine.SYNC_DELETIONS_CONFIRMED_LEGACY + " for this run")
        on_line("RESULT: SUCCESS (0)")
        return 0


def test_run_dialog_cloud_confirm_flow(qapp):
    fake = FakeCloudSyncRunner()
    dlg = RunDialog("docs", runner_factory=lambda: fake)
    dlg._start_sync_deletions()
    assert pump(qapp, lambda: dlg._entry.isEnabled())
    assert dlg._list.count() == 2
    dlg._entry.setText("I confirm")
    dlg._send_reply()
    assert pump(qapp, lambda: dlg._finished_rc == 0)
    assert fake.sent == ["I confirm\n"]
    dlg.deleteLater()


def test_run_dialog_cloud_decline_flow(qapp):
    fake = FakeCloudSyncRunner()
    dlg = RunDialog("docs", runner_factory=lambda: fake)
    dlg._start_sync_deletions()
    assert pump(qapp, lambda: dlg._entry.isEnabled())
    dlg._entry.setText("no")
    dlg._send_reply()
    assert pump(qapp, lambda: dlg._finished_rc == 75)
    dlg.deleteLater()


def test_run_dialog_accepts_the_legacy_marker(qapp):
    # Without the alias a sync-deletions run against a 0.2.x server would sit
    # at "re-verifying" forever.
    fake = LegacyEngineRunner()
    dlg = RunDialog("docs", runner_factory=lambda: fake)
    dlg._start_sync_deletions()
    assert pump(qapp, lambda: dlg._entry.isEnabled())
    dlg._entry.setText("I confirm")
    dlg._send_reply()
    assert pump(qapp, lambda: dlg._finished_rc == 0)
    dlg.deleteLater()


class PhraseInStreamRunner(FakeSyncRunner):
    """The literal phrase appears in the STREAM, before the prompt."""

    def run(self, on_line=None):
        on_line("prune    : type I confirm to delete these entries")
        on_line("  will delete: extra.txt")
        on_line(engine.SYNC_DELETIONS_PROMPT + " 1 entries: ")
        self._q.get(timeout=30)
        on_line("RESULT: NOT CONFIRMED -- nothing was transferred or deleted.")
        return 75


def test_dialog_never_auto_sends_the_phrase(qapp):
    """The hard rule: nothing in the stream may cause a reply.

    Only a human typing into the box can confirm. Closing the dialog sends a
    bare newline, which is an explicit DECLINE at the engine's prompt.
    """
    fake = PhraseInStreamRunner()
    dlg = RunDialog("docs", runner_factory=lambda: fake)
    dlg._start_sync_deletions()
    assert pump(qapp, lambda: dlg._entry.isEnabled())
    assert fake.sent == [], "the dialog must never confirm on its own"
    dlg.reject()
    assert fake.sent == ["\n"], "closing declines; it never confirms"
    dlg.deleteLater()


# --------------------------------------------------------------------------
# Cloud cards
# --------------------------------------------------------------------------

CLOUD_BLOCK = dict(
    BLOCK, BACKUP="docs-to-drive", DEST="gdrive:Backups/laptop",
    DEST_TYPE="cloud", RCLONE_REMOTE="gdrive", CLOUD_PROVIDER="drive",
    REMOTE_DEFINED="1", TRANSPORT="rclone",
)


def _card_text(card):
    from PySide6.QtWidgets import QLabel
    return "\n".join(w.text() for w in card.findChildren(QLabel))


def test_card_cloud_shows_the_account(qapp, monkeypatch):
    monkeypatch.setattr(engine, "rclone_path", lambda: "/usr/bin/rclone")
    card = BackupCard(dict(CLOUD_BLOCK), _FakeView())
    text = _card_text(card)
    assert "gdrive" in text and "Google Drive" in text
    assert "gdrive:Backups/laptop" in text
    card.deleteLater()


def test_card_cloud_warns_when_the_account_is_gone(qapp, monkeypatch):
    monkeypatch.setattr(engine, "rclone_path", lambda: "/usr/bin/rclone")
    card = BackupCard(dict(CLOUD_BLOCK, REMOTE_DEFINED="0"), _FakeView())
    assert "no longer configured" in _card_text(card)
    card.deleteLater()


def test_card_cloud_warns_when_rclone_is_missing(qapp, monkeypatch):
    monkeypatch.setattr(engine, "rclone_path", lambda: None)
    card = BackupCard(dict(CLOUD_BLOCK), _FakeView())
    assert "rclone is not installed" in _card_text(card)
    card.deleteLater()


def test_card_remote_cloud_warning_names_the_other_machine(qapp, monkeypatch):
    # In a REMOTE block these facts are about THAT machine; the warning must
    # not tell the user to fix anything here.
    monkeypatch.setattr(engine, "rclone_path", lambda: "/usr/bin/rclone")
    card = BackupCard(dict(CLOUD_BLOCK, REMOTE_DEFINED="0"), _FakeView(),
                      remote_label="workstation", remote_display="workstation")
    text = _card_text(card)
    assert "on workstation" in text
    card.deleteLater()


def test_humanize_schedule_cloud_is_not_drive_connect():
    # humanize_schedule keys on DEST_TYPE == "local". Rewriting that as
    # != "ssh" would print "on drive connect" for a cloud backup on */15.
    assert engine.humanize_schedule(
        {"SCHEDULE": "*/15 * * * *", "DEST_TYPE": "cloud", "TRIGGER": "0"}
    ) == engine.humanize_schedule(
        {"SCHEDULE": "*/15 * * * *", "DEST_TYPE": "ssh", "TRIGGER": "0"})
    assert "drive" not in engine.humanize_schedule(
        {"SCHEDULE": "*/15 * * * *", "DEST_TYPE": "cloud", "TRIGGER": "0"})


def test_is_file_line_ignores_rclone_stats():
    for chatter in ("Transferred:   \t 12.3 MiB / 12.3 MiB, 100%, 1 MiB/s, ETA 0s",
                    "Checks:                 100 / 100, 100%",
                    "Deleted:                  3 (files), 0 (dirs)",
                    "Elapsed time:           1.2s",
                    "Errors:                 0"):
        assert not is_file_line(chatter), chatter
    assert is_file_line("Documents/report.pdf")
