"""Self-update logic — no network, no Qt."""

import io
import json
import os
import subprocess

from app import updater


class _Resp(io.BytesIO):
    def __init__(self, payload: bytes, headers=None):
        super().__init__(payload)
        self.headers = headers or {}

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def _opener_for(payload: dict):
    def opener(req, timeout=0):
        return _Resp(json.dumps(payload).encode())
    return opener


def test_version_parsing_and_comparison():
    assert updater.parse_version("v0.1.0") == (0, 1, 0)
    assert updater.is_newer("v0.2.0", "0.1.0")
    assert updater.is_newer("1.0.0", "0.9.9")
    assert not updater.is_newer("0.1.0", "0.1.0")
    assert not updater.is_newer("v0.0.1", "0.1.0")
    assert not updater.is_newer("garbage", "0.1.0")


def test_check_latest_finds_newer_with_platform_asset():
    marker = updater._platform_asset_marker()
    payload = {"tag_name": "v0.2.0",
               "assets": [{"name": f"rsyncronizer-0.2.0{marker}",
                           "browser_download_url": "https://example.invalid/a"}]}
    info = updater.check_latest("0.1.0", opener=_opener_for(payload))
    assert info == {"version": "0.2.0", "asset_url": "https://example.invalid/a",
                    "asset_name": f"rsyncronizer-0.2.0{marker}"}


def test_check_latest_ignores_older_missing_asset_and_errors():
    assert updater.check_latest("0.1.0", opener=_opener_for(
        {"tag_name": "v0.1.0", "assets": []})) is None
    assert updater.check_latest("0.1.0", opener=_opener_for(
        {"tag_name": "v0.2.0", "assets": [{"name": "other.txt",
                                           "browser_download_url": "x"}]})) is None

    def boom(req, timeout=0):
        raise OSError("offline")
    assert updater.check_latest("0.1.0", opener=boom) is None


def test_download_streams_and_reports_progress(tmp_path):
    body = b"x" * 300000
    seen = []

    def opener(req, timeout=0):
        return _Resp(body, headers={"Content-Length": str(len(body))})

    path = updater.download("https://example.invalid/rsyncronizer.zip",
                            str(tmp_path), on_progress=lambda s, t: seen.append((s, t)),
                            opener=opener)
    assert open(path, "rb").read() == body
    assert seen[-1] == (len(body), len(body))


def test_apply_update_swaps_and_parks_old(tmp_path):
    target = tmp_path / "rsyncronizer"
    target.mkdir()
    (target / "marker.txt").write_text("old\n")

    stage = tmp_path / "payload" / "rsyncronizer"
    stage.mkdir(parents=True)
    (stage / "marker.txt").write_text("new\n")
    archive = tmp_path / "update.tar.gz"
    subprocess.run(["tar", "-czf", str(archive), "-C", str(tmp_path / "payload"),
                    "rsyncronizer"], check=True)

    launched = updater.apply_update(str(archive), str(target))
    assert launched == str(target)
    assert (target / "marker.txt").read_text() == "new\n"
    assert (tmp_path / "rsyncronizer.old" / "marker.txt").read_text() == "old\n"


def test_apply_update_rolls_back_on_bad_archive(tmp_path):
    target = tmp_path / "rsyncronizer"
    target.mkdir()
    (target / "marker.txt").write_text("old\n")

    stage = tmp_path / "payload" / "unrelated"
    stage.mkdir(parents=True)
    archive = tmp_path / "update.tar.gz"
    subprocess.run(["tar", "-czf", str(archive), "-C", str(tmp_path / "payload"),
                    "unrelated"], check=True)

    try:
        updater.apply_update(str(archive), str(target))
        raised = False
    except RuntimeError:
        raised = True
    assert raised
    assert (target / "marker.txt").read_text() == "old\n"


def test_install_target_none_when_running_from_source():
    assert updater.install_target() is None
