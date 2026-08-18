"""Support-the-author: the state helpers and the reminder dialog.

The counting itself lives in the bash engine and is covered by the bash
suite; here we prove the Python side reads/writes the same file correctly
and that the dialog's three outcomes do exactly what they claim."""

import os

import pytest

pyside = pytest.importorskip("PySide6")

from PySide6.QtWidgets import QApplication  # noqa: E402

from app import dialogs as dlgmod  # noqa: E402
from app import engine  # noqa: E402


@pytest.fixture(scope="module")
def qapp():
    app = QApplication.instance() or QApplication([])
    yield app


def _write_state(lines):
    path = engine.support_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


def test_state_defaults(engine_home):
    assert engine.support_state() == {
        "supported": False, "run_count": 0, "last_nag_count": 0}
    assert engine.support_due() is False


@pytest.mark.parametrize("run,nag,due", [
    (9, 0, False), (10, 0, True), (19, 10, False), (20, 10, True)])
def test_due_thresholds(engine_home, run, nag, due):
    _write_state([f"RUN_COUNT={run}", f"LAST_NAG_COUNT={nag}"])
    assert engine.support_due() is due


def test_mangled_counters_read_as_zero(engine_home):
    _write_state(["RUN_COUNT=lots", "LAST_NAG_COUNT=-3"])
    assert engine.support_state() == {
        "supported": False, "run_count": 0, "last_nag_count": 0}


def test_mark_supported_is_permanent(engine_home):
    _write_state(["RUN_COUNT=50", "LAST_NAG_COUNT=0"])
    assert engine.support_due()
    engine.mark_supported()
    assert engine.support_due() is False
    state = engine.support_state()
    assert state["supported"] is True
    assert state["run_count"] == 50


def test_defer_arms_next_window(engine_home):
    _write_state(["RUN_COUNT=12", "LAST_NAG_COUNT=0"])
    assert engine.support_due()
    engine.defer_support()
    state = engine.support_state()
    assert state["last_nag_count"] == 12
    assert state["supported"] is False
    assert engine.support_due() is False


def test_state_file_grammar(engine_home):
    """Every non-comment line must stay readable by the bash config_get."""
    engine.mark_supported()
    with open(engine.support_path(), encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            key, sep, _ = line.partition("=")
            assert sep == "="
            assert key
            assert all(c.isascii() and (c.isupper() or c.isdigit() or c == "_")
                       for c in key)


def test_dialog_buy_keeps_dialog_open(qapp, engine_home, monkeypatch):
    _write_state(["RUN_COUNT=10", "LAST_NAG_COUNT=0"])
    calls = []
    monkeypatch.setattr(dlgmod, "open_support_page", lambda: calls.append(1))
    dlg = dlgmod.SupportDialog()
    dlg.buy_btn.click()
    assert calls == [1]
    # Opening the page proves nothing, so the dialog stays unresolved and no
    # state changes.
    assert dlg.choice is None
    assert engine.support_state() == {
        "supported": False, "run_count": 10, "last_nag_count": 0}
    dlg.deleteLater()


def test_dialog_phrase_marks_supported(qapp, engine_home):
    _write_state(["RUN_COUNT=10", "LAST_NAG_COUNT=0"])
    dlg = dlgmod.SupportDialog()
    # Case-insensitive and whitespace-tolerant, like the engine's own
    # typed-confirmation phrases.
    dlg.phrase.setText("  I Have Supported ")
    assert dlg.choice == "supported"
    assert engine.support_state()["supported"] is True
    dlg.deleteLater()


def test_dialog_wrong_phrase_changes_nothing(qapp, engine_home):
    _write_state(["RUN_COUNT=10", "LAST_NAG_COUNT=0"])
    dlg = dlgmod.SupportDialog()
    dlg.phrase.setText("i have")
    dlg.phrase.setText("supported")
    assert dlg.choice is None
    assert engine.support_state() == {
        "supported": False, "run_count": 10, "last_nag_count": 0}
    dlg.deleteLater()


def test_dialog_later_defers(qapp, engine_home):
    _write_state(["RUN_COUNT=12", "LAST_NAG_COUNT=0"])
    dlg = dlgmod.SupportDialog()
    dlg.later_btn.click()
    assert dlg.choice == "later"
    assert engine.support_state()["last_nag_count"] == 12
    dlg.deleteLater()


def test_dialog_close_defers_exactly_once(qapp, engine_home):
    _write_state(["RUN_COUNT=30", "LAST_NAG_COUNT=0"])
    dlg = dlgmod.SupportDialog()
    dlg.reject()  # Esc and the window close button route through reject()
    assert engine.support_state()["last_nag_count"] == 30
    # A second reject (close after Esc) must not defer again.
    _write_state(["RUN_COUNT=40", "LAST_NAG_COUNT=30"])
    dlg.reject()
    assert engine.support_state()["last_nag_count"] == 30
    dlg.deleteLater()


def test_parse_porcelain_tolerates_support_header(engine_home):
    header, backups = engine.parse_porcelain(
        "NOW=x\nHOSTNAME=h\nSUPPORTED=yes\nSUPPORT_RUNS=12\n\n"
        "BACKUP=b\nRC=0\n")
    assert header["SUPPORTED"] == "yes"
    assert header["SUPPORT_RUNS"] == "12"
    assert backups[0]["BACKUP"] == "b"
