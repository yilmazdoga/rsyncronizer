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


# --------------------------------------------------------------------------
# A frozen app has no trust store unless we ship one
# --------------------------------------------------------------------------

def test_ssl_context_has_trust_anchors():
    """The whole 0.3.0 update failure in one assertion.

    PyInstaller bundles libssl/libcrypto but no CA bundle, and the bundled
    libcrypto looks for one at the BUILD machine's OPENSSLDIR
    (/Library/Frameworks/Python.framework/.../etc/openssl) -- a path that does
    not exist on a user's machine. A context with zero CAs cannot verify
    anything, so every HTTPS call failed and the update button never appeared.
    """
    ctx = updater._ssl_context()
    assert ctx.cert_store_stats()["x509_ca"] > 0, (
        "no trust anchors: the app cannot verify any TLS certificate")
    assert ctx.verify_mode == updater.ssl.CERT_REQUIRED, (
        "verification must stay ON -- an update is code we are about to run")


def test_ssl_context_prefers_the_shipped_bundle():
    # certifi is a declared runtime dependency precisely so the bundle carries
    # its own CAs rather than depending on a path outside the app.
    import os

    certifi = __import__("certifi")
    assert os.path.exists(certifi.where())


def test_check_latest_records_why_it_failed():
    # The bug behind the bug: every failure used to collapse into the same
    # `return None` as "you are up to date", so a dead button was
    # undiagnosable in the field.
    def boom(req, timeout=0):
        raise OSError("no route to host")

    assert updater.check_latest("0.1.0", opener=boom) is None
    assert "no route to host" in updater.LAST_ERROR
    assert updater.LAST_ERROR.startswith("OSError")


def test_check_latest_clears_the_error_when_it_succeeds():
    updater.LAST_ERROR = "stale"
    marker = updater._platform_asset_marker()
    payload = {"tag_name": "v0.2.0",
               "assets": [{"name": f"rsyncronizer-0.2.0{marker}",
                           "browser_download_url": "https://example.invalid/a"}]}
    assert updater.check_latest("0.1.0", opener=_opener_for(payload))
    assert updater.LAST_ERROR == ""


def test_being_up_to_date_is_not_an_error():
    updater.LAST_ERROR = ""
    assert updater.check_latest("9.9.9", opener=_opener_for({"tag_name": "v0.2.0"})) is None
    assert updater.LAST_ERROR == "", "up to date must not look like a failure"


def test_a_release_missing_this_platform_asset_says_so():
    updater.LAST_ERROR = ""
    assert updater.check_latest("0.1.0", opener=_opener_for(
        {"tag_name": "v0.2.0",
         "assets": [{"name": "something-else.txt", "browser_download_url": "x"}]})) is None
    assert "no asset ending in" in updater.LAST_ERROR
