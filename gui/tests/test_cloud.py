"""Cloud destinations: the Qt-free engine layer, and the wizard page.

The engine half needs no display; the wizard half runs offscreen. Nothing here
touches the network or a real rclone -- rclone is injected or monkeypatched
away, which is also how the "rclone is not installed" path gets exercised on
CI runners that have never heard of it.
"""

import json
import os

import pytest

from app import engine


# --------------------------------------------------------------------------
# Listing accounts
# --------------------------------------------------------------------------

class _Proc:
    def __init__(self, stdout="", returncode=0):
        self.stdout = stdout
        self.returncode = returncode


def _fake_run(monkeypatch, mapping):
    """Route subprocess.run by the flag that distinguishes the two listremotes
    forms, so the --json path and the --long fallback can be tested apart."""
    def run(argv, **kwargs):
        if "--json" in argv:
            return mapping.get("json", _Proc("", 1))
        if "--long" in argv:
            return mapping.get("long", _Proc("", 1))
        return _Proc("", 1)
    monkeypatch.setattr(engine.subprocess, "run", run)


def test_list_cloud_remotes_parses_json(monkeypatch):
    monkeypatch.setattr(engine, "rclone_path", lambda: "/usr/bin/rclone")
    _fake_run(monkeypatch, {"json": _Proc(json.dumps([
        {"name": "gdrive", "type": "drive", "description": "work"},
        {"name": "mys3", "type": "s3", "description": ""},
        {"name": "box", "type": "sftp", "description": ""},
    ]))})
    remotes = engine.list_cloud_remotes()
    assert [r["name"] for r in remotes] == ["gdrive", "mys3"], "sftp must be filtered out"
    assert remotes[0]["type"] == "drive"


def test_list_cloud_remotes_falls_back_to_long(monkeypatch):
    # --json is recent; the rclone in Ubuntu's archive predates it, and that is
    # exactly this audience.
    monkeypatch.setattr(engine, "rclone_path", lambda: "/usr/bin/rclone")
    _fake_run(monkeypatch, {
        "json": _Proc("", 1),
        "long": _Proc("gdrive: drive my work drive\nbox:    sftp\n"),
    })
    remotes = engine.list_cloud_remotes()
    assert [r["name"] for r in remotes] == ["gdrive"]
    assert remotes[0]["description"] == "my work drive"


def test_list_cloud_remotes_empty_when_rclone_absent(monkeypatch):
    monkeypatch.setattr(engine, "rclone_path", lambda: None)
    assert engine.list_cloud_remotes() == []


def test_rclone_missing_is_only_a_problem_for_a_cloud_backup(monkeypatch):
    # rclone is OPTIONAL. This is the rule the dashboard banner rests on.
    monkeypatch.setattr(engine, "rclone_path", lambda: None)
    assert engine.rclone_missing_for_backups([{"DEST_TYPE": "ssh"},
                                              {"DEST_TYPE": "local"}]) is False
    assert engine.rclone_missing_for_backups([{"DEST_TYPE": "cloud"}]) is True
    monkeypatch.setattr(engine, "rclone_path", lambda: "/usr/bin/rclone")
    assert engine.rclone_missing_for_backups([{"DEST_TYPE": "cloud"}]) is False


def test_check_tools_still_ignores_rclone(monkeypatch):
    monkeypatch.setattr(engine.shutil, "which", lambda name: None)
    assert engine.check_tools() == ["rsync", "ssh"], "rclone must not join the global banner"


# --------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------

def test_cloud_path_join_is_slash_safe():
    assert engine.cloud_dest_path({"cloud_bucket": "/b/", "dest_path": "/p/q/"}) == "b/p/q"
    assert engine.cloud_dest_path({"cloud_bucket": "", "dest_path": "p"}) == "p"
    assert engine.cloud_dest_path({"cloud_bucket": "b", "dest_path": ""}) == "b"


def test_cloud_dest_display_is_rclone_syntax():
    form = {"cloud_remote": "gdrive", "cloud_bucket": "", "dest_path": "Backups/laptop"}
    assert engine.cloud_dest_display(form) == "gdrive:Backups/laptop"


def test_rclone_name_re_rejects_a_repointing_name():
    for bad in ("g:drive", "a/b", "-oProxy", "", "with space"):
        assert not engine.RCLONE_NAME_RE.match(bad), bad
    for good in ("gdrive", "my.s3", "a_b-c", "d1"):
        assert engine.RCLONE_NAME_RE.match(good), good


def test_rclone_install_hint_names_a_package_manager(monkeypatch):
    monkeypatch.setattr(engine, "engine_root", lambda: "/nonexistent")
    hint = engine.rclone_install_hint()
    assert "rclone" in hint
    assert "brew" in hint or "apt" in hint


# --------------------------------------------------------------------------
# S3 credentials never reach an argv
# --------------------------------------------------------------------------

def test_s3_secret_is_never_on_the_command_line(tmp_path):
    creds = tmp_path / "credentials"
    engine.write_aws_profile("rsyncronizer-mys3", "AKIAX", "SUPERSECRET",
                             "eu-west-1", path=str(creds))
    assert oct(os.stat(creds).st_mode & 0o777) == "0o600"
    assert "SUPERSECRET" in creds.read_text()
    argv = engine.cloud_config_argv("mys3", "s3", {
        "provider": "AWS", "env_auth": "true", "profile": "rsyncronizer-mys3"})
    assert not any("SUPERSECRET" in a for a in argv), "the secret must stay off argv"
    assert "env_auth=true" in argv


def test_write_aws_profile_keeps_other_profiles(tmp_path):
    creds = tmp_path / "credentials"
    creds.write_text("[default]\naws_access_key_id = OTHER\n"
                     "aws_secret_access_key = KEEPME\n")
    engine.write_aws_profile("rsyncronizer-mys3", "AKIAX", "NEW", path=str(creds))
    text = creds.read_text()
    assert "KEEPME" in text, "an unrelated profile must survive"
    assert "rsyncronizer-mys3" in text


def test_aws_profile_exists(tmp_path):
    creds = tmp_path / "credentials"
    assert engine.aws_profile_exists("x", path=str(creds)) is False
    engine.write_aws_profile("x", "a", "b", path=str(creds))
    assert engine.aws_profile_exists("x", path=str(creds)) is True


# --------------------------------------------------------------------------
# The manifest's optional-entry marker
# --------------------------------------------------------------------------

def test_manifest_optional_marker():
    assert engine.manifest_entry("lib/common.sh") == ("lib/common.sh", True)
    assert engine.manifest_entry("?bin/rclone") == ("bin/rclone", False)


def test_engine_files_never_leaks_the_marker():
    # engine_files() returns PATHS. A caller joining '?bin/rclone' onto a root
    # would create a directory literally named '?bin'.
    assert not any(f.startswith("?") for f in engine.engine_files())
    assert ("bin/rclone", False) in engine.engine_manifest()


def test_materialize_skips_a_missing_optional_entry(engine_home, monkeypatch, tmp_path):
    src = tmp_path / "src"
    (src / "lib").mkdir(parents=True)
    (src / "lib" / "engine-manifest.txt").write_text(
        "lib/a.sh\nrsync-ignore.txt\n?bin/rclone\n")
    (src / "lib" / "a.sh").write_text("#!/bin/bash\n")
    (src / "rsync-ignore.txt").write_text("- .DS_Store\n")
    monkeypatch.setattr(engine, "resource_root", lambda: str(src))
    root = engine.materialize()
    assert os.path.exists(os.path.join(root, "lib", "a.sh"))
    assert not os.path.exists(os.path.join(root, "bin", "rclone"))


def test_materialize_ships_and_chmods_a_present_optional_entry(engine_home, monkeypatch, tmp_path):
    src = tmp_path / "src2"
    (src / "lib").mkdir(parents=True)
    (src / "bin").mkdir(parents=True)
    (src / "lib" / "engine-manifest.txt").write_text(
        "rsync-ignore.txt\n?bin/rclone\n")
    (src / "bin" / "rclone").write_text("binary")
    (src / "rsync-ignore.txt").write_text("- .DS_Store\n")
    monkeypatch.setattr(engine, "resource_root", lambda: str(src))
    root = engine.materialize()
    shipped = os.path.join(root, "bin", "rclone")
    assert os.path.exists(shipped)
    # PyInstaller's datas drops the executable bit; materialize must restore it.
    assert os.access(shipped, os.X_OK)


# --------------------------------------------------------------------------
# Answers
# --------------------------------------------------------------------------

CLOUD_FORM = {
    "name": "docs-to-drive", "source": "/home/me/docs", "dest_kind": "cloud",
    "cloud_remote": "gdrive", "cloud_type": "drive", "cloud_bucket": "",
    "dest_path": "Backups/laptop", "create_dest": True,
    "schedule": True, "schedule_choice": "1", "schedule_custom": "",
}


def test_build_answers_cloud_oauth():
    a = engine.build_answers(dict(CLOUD_FORM))
    assert a["A_DEST_KIND"] == "3"
    assert a["A_RCLONE_REMOTE"] == "gdrive"
    assert a["A_CLOUD_PROVIDER"] == "2"          # setup.sh's menu order
    assert a["A_DEST_PATH"] == "Backups/laptop"
    assert a["A_CREATE_DEST"] == "y"
    assert a["A_SCHEDULE_YN"] == "y" and a["A_CRON_CONFIRM"] == "y"
    for stale in ("A_HOST", "A_USER", "A_VOLUME_ROOT", "A_INSTALL_TRIGGER"):
        assert stale not in a, stale


def test_build_answers_cloud_s3_folds_the_bucket_into_the_path():
    form = dict(CLOUD_FORM, cloud_type="s3", cloud_bucket="my-bucket",
                dest_path="backups/laptop")
    a = engine.build_answers(form)
    assert a["A_DEST_PATH"] == "my-bucket/backups/laptop"
    assert a["A_CLOUD_PROVIDER"] == "1"


def test_build_answers_cloud_s3_bucket_root():
    form = dict(CLOUD_FORM, cloud_type="s3", cloud_bucket="my-bucket", dest_path="")
    assert engine.build_answers(form)["A_DEST_PATH"] == "my-bucket"


def test_confirmation_marker_is_transport_neutral():
    # The engine emits ONE marker for both transports; the mechanism goes on
    # the next line, which nothing classifies.
    assert "delete-after" not in engine.SYNC_DELETIONS_CONFIRMED
    assert "rsync" not in engine.SYNC_DELETIONS_CONFIRMED
    assert "rclone" not in engine.SYNC_DELETIONS_CONFIRMED
    # And the 0.2.x wording is still recognised, for remote engines.
    assert engine.SYNC_DELETIONS_CONFIRMED_LEGACY == "confirmed; --delete-after enabled"


# --------------------------------------------------------------------------
# The wizard page
# --------------------------------------------------------------------------

pytest.importorskip("PySide6")

from PySide6.QtWidgets import QApplication  # noqa: E402

from app.wizard import BackupWizard  # noqa: E402


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


REMOTES = [
    {"name": "gdrive", "type": "drive", "description": ""},
    {"name": "mys3", "type": "s3", "description": ""},
]


def _wizard(monkeypatch, qapp, remotes=REMOTES, have_rclone=True):
    monkeypatch.setattr(engine, "rclone_path",
                        lambda: "/usr/bin/rclone" if have_rclone else None)
    monkeypatch.setattr(engine, "list_cloud_remotes", lambda: list(remotes))
    monkeypatch.setattr(engine, "rclone_install_hint", lambda: "brew install rclone")
    wiz = BackupWizard()
    wiz.dest.cloud_radio.setChecked(True)
    wiz.dest.initializePage()
    return wiz


def test_wizard_construction_does_not_shell_rclone(monkeypatch, qapp):
    # Listing remotes is a subprocess; BackupWizard() is built on every window
    # open and in these tests, so it must not happen in __init__.
    def boom():
        raise AssertionError("list_cloud_remotes must not run during __init__")
    monkeypatch.setattr(engine, "list_cloud_remotes", boom)
    BackupWizard().deleteLater()


def test_wizard_cloud_incomplete_without_rclone(monkeypatch, qapp):
    wiz = _wizard(monkeypatch, qapp, have_rclone=False)
    assert wiz.dest.isComplete() is False
    assert not wiz.dest.rclone_warn.isHidden()
    wiz.deleteLater()


def test_wizard_cloud_incomplete_without_an_account(monkeypatch, qapp):
    wiz = _wizard(monkeypatch, qapp, remotes=[])
    assert wiz.dest.isComplete() is False
    assert wiz.dest.selected_remote() is None
    wiz.deleteLater()


def test_wizard_cloud_s3_requires_a_bucket(monkeypatch, qapp):
    wiz = _wizard(monkeypatch, qapp)
    wiz.dest.cloud_remote.setCurrentIndex(1)      # mys3
    wiz.dest.cloud_dest.setText("backups")
    assert wiz.dest.isComplete() is False
    wiz.dest.cloud_bucket.setText("my-bucket")
    assert wiz.dest.isComplete() is True
    wiz.deleteLater()


def test_wizard_cloud_oauth_needs_no_bucket(monkeypatch, qapp):
    wiz = _wizard(monkeypatch, qapp)
    wiz.dest.cloud_remote.setCurrentIndex(0)      # gdrive
    assert wiz.dest.cloud_bucket.isHidden()
    assert wiz.dest.isComplete() is True
    wiz.deleteLater()


def test_wizard_cloud_form_to_answers(monkeypatch, qapp):
    wiz = _wizard(monkeypatch, qapp)
    wiz.basics.name.setText("docs-to-drive")
    wiz.basics.source.setText("/home/me/docs")
    wiz.dest.cloud_remote.setCurrentIndex(0)
    wiz.dest.cloud_dest.setText("Backups/laptop")
    form = wiz.form_state()
    assert form["dest_kind"] == "cloud"
    assert form["cloud_remote"] == "gdrive"
    a = engine.build_answers(form)
    assert a["A_DEST_KIND"] == "3"
    assert a["A_RCLONE_REMOTE"] == "gdrive"
    assert a["A_DEST_PATH"] == "Backups/laptop"
    wiz.deleteLater()


def test_wizard_switching_kind_leaves_no_cloud_keys(monkeypatch, qapp):
    wiz = _wizard(monkeypatch, qapp)
    wiz.basics.name.setText("x")
    wiz.basics.source.setText("/s")
    wiz.dest.cloud_dest.setText("Backups/laptop")
    assert "cloud_remote" in wiz.form_state()
    wiz.dest.ssh_radio.setChecked(True)
    wiz.dest.host.setText("box")
    wiz.dest.ssh_dest.setText("/backup")
    form = wiz.form_state()
    assert form["dest_kind"] == "ssh"
    assert not any(k.startswith("cloud_") for k in form), form
    assert "A_RCLONE_REMOTE" not in engine.build_answers(form)
    wiz.deleteLater()


def test_wizard_kind_helper(monkeypatch, qapp):
    wiz = _wizard(monkeypatch, qapp)
    assert wiz.dest.kind() == "cloud"
    wiz.dest.drive_radio.setChecked(True)
    assert wiz.dest.kind() == "local"
    wiz.dest.ssh_radio.setChecked(True)
    assert wiz.dest.kind() == "ssh"
    wiz.deleteLater()


def test_schedule_page_offers_cron_for_cloud(monkeypatch, qapp):
    # Cloud runs on a clock like SSH; only a plugged-in drive gets the trigger
    # chain. The natural-looking `!= "ssh"` would get this backwards.
    wiz = _wizard(monkeypatch, qapp)
    wiz.sched.initializePage()
    assert not wiz.sched.schedule_on.isHidden()
    assert wiz.sched.trigger_on.isHidden()
    wiz.deleteLater()


def test_review_page_shows_the_landing_path_and_the_provider(monkeypatch, qapp, tmp_path):
    from app.wizard import ReviewPage

    src = tmp_path / "srcdata"
    src.mkdir()
    wiz = _wizard(monkeypatch, qapp)
    wiz.basics.name.setText("x")
    wiz.basics.source.setText(str(src))
    wiz.dest.cloud_remote.setCurrentIndex(0)
    wiz.dest.cloud_dest.setText("Backups/laptop")
    page = ReviewPage(wiz)
    page.initializePage()
    text = page.summary.text()
    assert "gdrive:Backups/laptop/srcdata/" in text
    assert "Google Drive" in text
    assert "750 GB" in text, "the provider's own caveat belongs on the review page"
    assert "symlinks" in text
    wiz.deleteLater()
