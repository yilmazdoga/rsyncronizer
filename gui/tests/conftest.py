import os
import sys

import pytest

# Widget tests must run without a display (CI, ssh sessions).
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


@pytest.fixture
def engine_home(tmp_path, monkeypatch):
    """Point the app at a throwaway engine tree."""
    home = tmp_path / "engine-home"
    monkeypatch.setenv("RSYNC_BACKUP_GUI_HOME", str(home))
    return str(home)
