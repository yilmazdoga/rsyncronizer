"""Engine-layer tests: no Qt, no display, no network. The setup.sh test is a
true end-to-end: it drives the REAL script headlessly into a scratch tree."""

import os
import stat
import textwrap

from app import engine


# --------------------------------------------------------------------------
# Answers mapping
# --------------------------------------------------------------------------

def test_build_answers_ssh_with_schedule():
    a = engine.build_answers({
        "name": "docs", "source": "/tmp/src", "dest_kind": "ssh",
        "host": "box", "user": "me", "dest_path": "/backup",
        "schedule": True, "schedule_choice": "1",
    })
    assert a["A_DEST_KIND"] == "1"
    assert a["A_USER"] == "me"
    assert a["A_SCHEDULE_YN"] == "y"
    assert a["A_SCHEDULE_CHOICE"] == "1"
    assert a["A_CRON_CONFIRM"] == "y"
    assert a["A_CONFIRM_LANDING"] == "yes"
    assert a["A_RUN_DRY_RUN"] == "n"
    assert "A_SCHEDULE_CUSTOM" not in a


def test_build_answers_blank_user_is_none_sentinel():
    a = engine.build_answers({
        "name": "docs", "source": "/tmp/src", "dest_kind": "ssh",
        "host": "box", "user": "", "dest_path": "/backup",
    })
    # An absent A_USER would mean "accept the ssh -G prefill"; an explicitly
    # blank field must force a blank user instead.
    assert a["A_USER"] == "@none"
    assert "A_SCHEDULE_YN" not in a


def test_build_answers_local_trigger():
    a = engine.build_answers({
        "name": "ssd", "source": "/tmp/src", "dest_kind": "local",
        "volume_root": "/Volumes/X", "dest_path": "/Volumes/X/mac",
        "install_trigger": True, "trigmode": "2",
    })
    assert a["A_DEST_KIND"] == "2"
    assert a["A_VOLUME_ROOT"] == "/Volumes/X"
    assert a["A_INSTALL_TRIGGER"] == "y"
    assert a["A_TRIGMODE"] == "2"


def test_write_answers_mode_and_grammar(engine_home):
    path = engine.write_answers({"A_NAME": "x", "A_SOURCE": "/s"})
    try:
        mode = stat.S_IMODE(os.stat(path).st_mode)
        assert mode == 0o600
        content = open(path).read()
        assert "A_NAME=x\n" in content and "A_SOURCE=/s\n" in content
    finally:
        os.unlink(path)


# --------------------------------------------------------------------------
# Porcelain parsing
# --------------------------------------------------------------------------

PORCELAIN = textwrap.dedent("""\
    NOW=2026-08-10 12:00:00 +0100
    RSYNC_BIN=/usr/bin/rsync
    RSYNC_FLAVOUR=openrsync

    BACKUP=alpha
    SRC=/home/me/docs
    RC=0
    VERDICT=SUCCESS
    NEVER_RAN=0

    BACKUP=beta
    NEVER_RAN=1
""")


def test_parse_porcelain():
    header, backups = engine.parse_porcelain(PORCELAIN)
    assert header["RSYNC_FLAVOUR"] == "openrsync"
    assert [b["BACKUP"] for b in backups] == ["alpha", "beta"]
    assert backups[0]["VERDICT"] == "SUCCESS"
    assert backups[1]["NEVER_RAN"] == "1"


# --------------------------------------------------------------------------
# Materialization
# --------------------------------------------------------------------------

def test_materialize_creates_engine_and_upgrade_preserves_state(engine_home):
    root = engine.materialize()
    # Everything in the manifest lands; scripts and the CLI are executable.
    for rel in engine.engine_files():
        assert os.path.isfile(os.path.join(root, rel)), rel
    assert os.access(os.path.join(root, "setup.sh"), os.X_OK)
    assert os.access(os.path.join(root, "remote.sh"), os.X_OK)
    assert os.access(os.path.join(root, "cli", "rsyncronizer"), os.X_OK)

    # User state must survive an engine refresh.
    cfg = os.path.join(root, "config", "keepme")
    os.makedirs(cfg)
    open(os.path.join(cfg, "source.txt"), "w").write("/tmp\n")
    open(os.path.join(root, "VERSION"), "w").write("0.0.0-old\n")
    engine.materialize()
    assert open(os.path.join(root, "VERSION")).read().strip() == engine.bundled_version()
    assert os.path.isfile(os.path.join(cfg, "source.txt"))

    # Regression: a stale engine file with the SAME version must be refreshed
    # too -- a VERSION gate here once left the installed lib silently lagging
    # the bundled one ("triggered by" read unknown forever).
    lib = os.path.join(root, "lib", "common.sh")
    open(lib, "w").write("# stale placeholder\n")
    engine.materialize()
    assert "run_backup" in open(lib).read()


# --------------------------------------------------------------------------
# pty streaming
# --------------------------------------------------------------------------

def test_run_streaming_delivers_lines_and_rc(tmp_path):
    script = tmp_path / "t.sh"
    script.write_text("#!/bin/bash\necho one\n[ -t 1 ] && echo have-tty\nexit 3\n")
    script.chmod(0o755)
    lines = []
    rc = engine.run_streaming(["/bin/bash", str(script)], on_line=lines.append)
    assert rc == 3
    assert "one" in lines
    # The whole point of the pty: the engine sees a terminal.
    assert "have-tty" in lines


# --------------------------------------------------------------------------
# End-to-end: the real setup.sh + status.sh through the app's own plumbing
# --------------------------------------------------------------------------

def test_setup_and_status_end_to_end(engine_home, tmp_path):
    src = tmp_path / "srcdata"
    (src / "sub").mkdir(parents=True)
    (src / "a.txt").write_text("hello\n")

    answers = engine.build_answers({
        "name": "e2e-test", "source": str(src), "dest_kind": "ssh",
        "host": "selftest.invalid", "user": "", "dest_path": str(tmp_path / "dest"),
    })
    transcript = []
    rc = engine.run_setup(answers, on_line=transcript.append)
    assert rc == 0, "\n".join(transcript[-10:])

    root = engine.engine_root()
    assert os.path.isfile(os.path.join(root, "config", "e2e-test", "source.txt"))
    assert os.access(os.path.join(root, "backups", "e2e-test.sh"), os.X_OK)

    status_rc, header, backups = engine.status()
    names = [b["BACKUP"] for b in backups]
    assert "e2e-test" in names
    e2e = backups[names.index("e2e-test")]
    assert e2e["NEVER_RAN"] == "1"
    assert status_rc == 0  # never-ran without a schedule is not unhealthy

    # Removal: schedule bookkeeping goes, source data stays.
    transcript.clear()
    rc = engine.remove_backup("e2e-test", on_line=transcript.append)
    assert rc == 0, "\n".join(transcript[-10:])
    assert not os.path.isdir(os.path.join(root, "config", "e2e-test"))
    assert not os.path.isdir(os.path.join(root, "logs", "e2e-test"))
    assert not os.path.exists(os.path.join(root, "backups", "e2e-test.sh"))
    assert (src / "a.txt").exists()
    _, _, backups = engine.status()
    assert "e2e-test" not in [b["BACKUP"] for b in backups]
